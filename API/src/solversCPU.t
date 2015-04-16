
local S = require("std")
local util = require("util")
local C = util.C

solversCPU = {}

solversCPU.gradientDescentCPU = function(Problem, tbl, vars)
	local struct PlanData(S.Object) {
		plan : opt.Plan
		gradW : int
		gradH : int
		gradient : vars.unknownType
		dims : int64[#vars.dims + 1]
	}

	local computeCost = util.makeComputeCost(tbl, vars.imagesAll)
	local computeGradient = util.makeComputeGradient(tbl, vars.unknownType, vars.imagesAll)

	local terra impl(data_ : &opaque, imageBindings : &&opt.ImageBinding, params_ : &opaque)

		var pd = [&PlanData](data_)
		var params = [&double](params_)
		var dims = pd.dims

		var [vars.imagesAll] = [util.getImages(vars, imageBindings, dims)]

		-- TODO: parameterize these
		var initialLearningRate = 0.01
		var maxIters = 200
		var tolerance = 1e-10

		-- Fixed constants (these do not need to be parameterized)
		var learningLoss = 0.8
		var learningGain = 1.1
		var minLearningRate = 1e-25

		var learningRate = initialLearningRate

		for iter = 0, maxIters do
			var startCost = computeCost(vars.imagesAll)
			log("iteration %d, cost=%f, learningRate=%f\n", iter, startCost, learningRate)
			--C.getchar()

			computeGradient(pd.gradient, vars.imagesAll)
			
			--
			-- move along the gradient by learningRate
			--
			var maxDelta = 0.0
			for h = 0,pd.gradH do
				for w = 0,pd.gradW do
					var addr = &vars.unknownImage(w, h)
					var delta = learningRate * pd.gradient(w, h)
					@addr = @addr - delta
					maxDelta = util.max(C.fabsf(delta), maxDelta)
				end
			end

			--
			-- update the learningRate
			--
			var endCost = computeCost(vars.imagesAll)
			if endCost < startCost then
				learningRate = learningRate * learningGain

				if maxDelta < tolerance then
					log("terminating, maxDelta=%f\n", maxDelta)
					break
				end
			else
				learningRate = learningRate * learningLoss

				if learningRate < minLearningRate then
					log("terminating, learningRate=%f\n", learningRate)
					break
				end
			end
		end
	end

	local terra makePlan(actualDims : &uint64) : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl
		pd.dims[0] = 1
		for i = 0,[#vars.dims] do
			pd.dims[i+1] = actualDims[i]
		end

		pd.gradW = pd.dims[vars.gradWIndex]
		pd.gradH = pd.dims[vars.gradHIndex]

		pd.gradient:initCPU(pd.gradW, pd.gradH)

		return &pd.plan
	end
	return Problem:new { makePlan = makePlan }
end

solversCPU.conjugateGradientCPU = function(Problem, tbl, vars)
	local struct PlanData(S.Object) {
		plan : opt.Plan
		gradW : int
		gradH : int
		costW : int
		costH : int
		dims : int64[#vars.dims + 1]
				
		currentValues : vars.unknownType
		currentResiduals : vars.unknownType
		
		gradient : vars.unknownType
		prevGradient : vars.unknownType
		
		searchDirection : vars.unknownType
	}
	
	local computeCost = util.makeComputeCost(tbl, vars.imagesAll)
	local computeSearchCost = util.makeSearchCost(tbl, vars.unknownType, vars.dataImages)
	local computeResiduals = util.makeComputeResiduals(tbl, vars.unknownType, vars.dataImages)
	local lineSearchBruteForce = util.makeLineSearchBruteForce(tbl, vars.unknownType, vars.dataImages)
	local lineSearchQuadraticMinimum = util.makeLineSearchQuadraticMinimum(tbl, vars.unknownType, vars.dataImages)
	
	local terra impl(data_ : &opaque, imageBindings : &&opt.ImageBinding, params_ : &opaque)

		var pd = [&PlanData](data_)
		var params = [&double](params_)
		var dims = pd.dims

		var [vars.imagesAll] = [util.getImages(vars, imageBindings, dims)]
		
		var maxIters = 1000
		
		var prevBestAlpha = 0.0

		for iter = 0, maxIters do

			var iterStartCost = computeCost(vars.imagesAll)
			log("iteration %d, cost=%f\n", iter, iterStartCost)

			--
			-- compute the gradient
			--
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					pd.gradient(w, h) = tbl.gradient(w, h, vars.imagesAll)
				end
			end

			--
			-- compute the search direction
			--
			var beta = 0.0
			if iter == 0 then
				for h = 0, pd.gradH do
					for w = 0, pd.gradW do
						pd.searchDirection(w, h) = -pd.gradient(w, h)
					end
				end
			else
				var num = 0.0
				var den = 0.0
				
				--
				-- Polak-Ribiere conjugacy
				-- 
				for h = 0, pd.gradH do
					for w = 0, pd.gradW do
						var g = pd.gradient(w, h)
						var p = pd.prevGradient(w, h)
						num = num + (-g * (-g + p))
						den = den + p * p
					end
				end
				beta = util.max(num / den, 0.0)
				
				var epsilon = 1e-5
				if den > -epsilon and den < epsilon then
					beta = 0.0
				end
				
				for h = 0, pd.gradH do
					for w = 0, pd.gradW do
						pd.searchDirection(w, h) = -pd.gradient(w, h) + beta * pd.searchDirection(w, h)
					end
				end
			end
			
			C.memcpy(pd.prevGradient.impl.data, pd.gradient.impl.data, sizeof(float) * pd.gradW * pd.gradH)
			C.memcpy(pd.currentValues.impl.data, vars.unknownImage.impl.data, sizeof(float) * pd.gradW * pd.gradH)
			
			--
			-- line search
			--
			computeResiduals(pd.currentValues, pd.currentResiduals, vars.dataImages)
			
			-- NOTE: this approach to line search will have unexpected behavior if the cost function
			-- returns double-precision, but residuals are stored at single precision!
			
			var bestAlpha = 0.0
			
			var useBruteForce = (iter <= 1) or prevBestAlpha == 0.0
			if not useBruteForce then
				
				bestAlpha = lineSearchQuadraticMinimum(pd.currentValues, pd.currentResiduals, pd.searchDirection, vars.unknownImage, prevBestAlpha, vars.dataImages)
				
				if bestAlpha == 0.0 then useBruteForce = true end
			end
			
			if useBruteForce then
				log("brute-force line search\n")
				bestAlpha = lineSearchBruteForce(pd.currentValues, pd.currentResiduals, pd.searchDirection, vars.unknownImage, vars.dataImages)
			end
			
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					vars.unknownImage(w, h) = pd.currentValues(w, h) + bestAlpha * pd.searchDirection(w, h)
				end
			end
			
			prevBestAlpha = bestAlpha
			
			--if iter % 20 == 0 then C.getchar() end
			
			log("alpha=%12.12f, beta=%12.12f\n\n", bestAlpha, beta)
			if bestAlpha == 0.0 and beta == 0.0 then
			
				--[[var file = C.fopen("C:/code/debug.txt", "wb")

				var debugAlpha = 0.0
				for lineSearchIndex = 0, 400 do
					var searchCost = computeSearchCost(pd.currentValues, pd.currentResiduals, pd.searchDirection, debugAlpha, vars.unknownImage, vars.dataImages)
					
					C.fprintf(file, "%15.15f\t%15.15f\n", debugAlpha * 1000.0, searchCost)
					
					debugAlpha = debugAlpha + 1e-8
				end
				
				C.fclose(file)
				log("debug alpha outputted")
				C.getchar()]]
				
				break
			end
		end
	end

	local terra makePlan(actualDims : &uint64) : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl
		pd.dims[0] = 1
		for i = 0,[#vars.dims] do
			pd.dims[i+1] = actualDims[i]
		end

		pd.gradW = pd.dims[vars.gradWIndex]
		pd.gradH = pd.dims[vars.gradHIndex]
		
		pd.costW = pd.dims[vars.costWIndex]
		pd.costH = pd.dims[vars.costHIndex]

		pd.currentValues:initCPU(pd.gradW, pd.gradH)
		
		pd.currentResiduals:initCPU(pd.costW, pd.costH)
		
		pd.gradient:initCPU(pd.gradW, pd.gradH)
		pd.prevGradient:initCPU(pd.gradW, pd.gradH)
		
		pd.searchDirection:initCPU(pd.gradW, pd.gradH)

		return &pd.plan
	end
	return Problem:new { makePlan = makePlan }
end

solversCPU.linearizedConjugateGradientCPU = function(Problem, tbl, vars)
	local struct PlanData(S.Object) {
		plan : opt.Plan
		gradW : int
		gradH : int
		dims : int64[#vars.dims + 1]
		
		b : vars.unknownType
		r : vars.unknownType
		p : vars.unknownType
		zeroes : vars.unknownType
		Ap : vars.unknownType
	}
	
	local computeCost = util.makeComputeCost(tbl, vars.imagesAll)
	local imageInnerProduct = util.makeImageInnerProduct(vars.unknownType)

	local terra impl(data_ : &opaque, imageBindings : &&opt.ImageBinding, params_ : &opaque)
		var pd = [&PlanData](data_)
		var params = [&double](params_)
		var dims = pd.dims

		var [vars.imagesAll] = [util.getImages(vars, imageBindings, dims)]
		
		-- TODO: parameterize these
		var maxIters = 1000
		var tolerance = 1e-5

		for h = 0, pd.gradH do
			for w = 0, pd.gradW do
				pd.r(w, h) = -tbl.gradient(w, h, vars.unknownImage, vars.dataImages)
				pd.b(w, h) = tbl.gradient(w, h, pd.zeroes, vars.dataImages)
				pd.p(w, h) = pd.r(w, h)
			end
		end
		
		var rTr = imageInnerProduct(pd.r, pd.r)

		for iter = 0,maxIters do

			var iterStartCost = computeCost(vars.imagesAll)
			
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					pd.Ap(w, h) = tbl.gradient(w, h, pd.p, vars.dataImages) - pd.b(w, h)
				end
			end
			
			var den = imageInnerProduct(pd.p, pd.Ap)
			var alpha = rTr / den
			
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					vars.unknownImage(w, h) = vars.unknownImage(w, h) + alpha * pd.p(w, h)
					pd.r(w, h) = pd.r(w, h) - alpha * pd.Ap(w, h)
				end
			end
			
			var rTrNew = imageInnerProduct(pd.r, pd.r)
			
			log("iteration %d, cost=%f, rTr=%f\n", iter, iterStartCost, rTrNew)
			
			if(rTrNew < tolerance) then break end
			
			var beta = rTrNew / rTr
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					pd.p(w, h) = pd.r(w, h) + beta * pd.p(w, h)
				end
			end
			
			rTr = rTrNew
		end
		
		var finalCost = computeCost(vars.imagesAll)
		log("final cost=%f\n", finalCost)
	end

	local terra makePlan(actualDims : &uint64) : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl
		pd.dims[0] = 1
		for i = 0,[#vars.dims] do
			pd.dims[i+1] = actualDims[i]
		end

		pd.gradW = pd.dims[vars.gradWIndex]
		pd.gradH = pd.dims[vars.gradHIndex]

		pd.b:initCPU(pd.gradW, pd.gradH)
		pd.r:initCPU(pd.gradW, pd.gradH)
		pd.p:initCPU(pd.gradW, pd.gradH)
		pd.Ap:initCPU(pd.gradW, pd.gradH)
		pd.zeroes:initCPU(pd.gradW, pd.gradH)
		
		return &pd.plan
	end
	return Problem:new { makePlan = makePlan }
end

solversCPU.linearizedPreconditionedConjugateGradientCPU = function(Problem, tbl, vars)
	local struct PlanData(S.Object) {
		plan : opt.Plan
		gradW : int
		gradH : int
		dims : int64[#vars.dims + 1]
		
		b : vars.unknownType
		r : vars.unknownType
		z : vars.unknownType
		p : vars.unknownType
		MInv : vars.unknownType
		Ap : vars.unknownType
		zeroes : vars.unknownType
	}
	
	local computeCost = util.makeComputeCost(tbl, vars.imagesAll)
	local imageInnerProduct = util.makeImageInnerProduct(vars.unknownType)

	local terra impl(data_ : &opaque, imageBindings : &&opt.ImageBinding, params_ : &opaque)
		var pd = [&PlanData](data_)
		var params = [&double](params_)
		var dims = pd.dims

		var [vars.imagesAll] = [util.getImages(vars, imageBindings, dims)]

		-- TODO: parameterize these
		var maxIters = 1000
		var tolerance = 1e-5

		for h = 0, pd.gradH do
			for w = 0, pd.gradW do
				pd.MInv(w, h) = 1.0 / tbl.gradientPreconditioner(w, h)
			end
		end
		
		for h = 0, pd.gradH do
			for w = 0, pd.gradW do
				pd.r(w, h) = -tbl.gradient(w, h, vars.unknownImage, vars.dataImages)
				pd.b(w, h) = tbl.gradient(w, h, pd.zeroes, vars.dataImages)
				pd.z(w, h) = pd.MInv(w, h) * pd.r(w, h)
				pd.p(w, h) = pd.z(w, h)
			end
		end
		
		for iter = 0,maxIters do

			var iterStartCost = computeCost(vars.imagesAll)
			
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					pd.Ap(w, h) = tbl.gradient(w, h, pd.p, vars.dataImages) - pd.b(w, h)
				end
			end
			
			var rTzStart = imageInnerProduct(pd.r, pd.z)
			var den = imageInnerProduct(pd.p, pd.Ap)
			var alpha = rTzStart / den
			
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					vars.unknownImage(w, h) = vars.unknownImage(w, h) + alpha * pd.p(w, h)
					pd.r(w, h) = pd.r(w, h) - alpha * pd.Ap(w, h)
				end
			end
			
			var rTr = imageInnerProduct(pd.r, pd.r)
			
			log("iteration %d, cost=%f, rTr=%f\n", iter, iterStartCost, rTr)
			
			if(rTr < tolerance) then break end
			
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					pd.z(w, h) = pd.MInv(w, h) * pd.r(w, h)
				end
			end
			
			var beta = imageInnerProduct(pd.z, pd.r) / rTzStart
			
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					pd.p(w, h) = pd.z(w, h) + beta * pd.p(w, h)
				end
			end
		end
		
		var finalCost = computeCost(vars.imagesAll)
		log("final cost=%f\n", finalCost)
	end

	local terra makePlan(actualDims : &uint64) : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl
		pd.dims[0] = 1
		for i = 0,[#vars.dims] do
			pd.dims[i+1] = actualDims[i]
		end

		pd.gradW = pd.dims[vars.gradWIndex]
		pd.gradH = pd.dims[vars.gradHIndex]

		pd.b:initCPU(pd.gradW, pd.gradH)
		pd.r:initCPU(pd.gradW, pd.gradH)
		pd.z:initCPU(pd.gradW, pd.gradH)
		pd.p:initCPU(pd.gradW, pd.gradH)
		pd.MInv:initCPU(pd.gradW, pd.gradH)
		pd.Ap:initCPU(pd.gradW, pd.gradH)
		pd.zeroes:initCPU(pd.gradW, pd.gradH)
		
		return &pd.plan
	end
	return Problem:new { makePlan = makePlan }
end

--[[vars.dataImages = terralib.newlist()
for i = 2,#vars.imagesAll do
	vars.dataImages:insert(vars.imagesAll[i])
end]]

solversCPU.lbfgsCPU = function(Problem, tbl, vars)

	local maxIters = 10
	
	local struct PlanData(S.Object) {
		plan : opt.Plan
		gradW : int
		gradH : int
		costW : int
		costH : int
		dims : int64[#vars.dims + 1]
		
		gradient : vars.unknownType
		prevGradient : vars.unknownType
				
		p : vars.unknownType
		sList : vars.unknownType[maxIters]
		yList : vars.unknownType[maxIters]
		syProduct : float[maxIters]
		yyProduct : float[maxIters]
		alphaList : float[maxIters]
		
		-- variables used for line search
		currentValues : vars.unknownType
		currentResiduals : vars.unknownType
	}
	
	local computeCost = util.makeComputeCost(tbl, vars.imagesAll)
	local computeGradient = util.makeComputeGradient(tbl, vars.unknownType, vars.imagesAll)
	local computeSearchCost = util.makeSearchCost(tbl, vars.unknownType, vars.dataImages)
	local computeResiduals = util.makeComputeResiduals(tbl, vars.unknownType, vars.dataImages)
	local imageInnerProduct = util.makeImageInnerProduct(vars.unknownType)
	
	local terra impl(data_ : &opaque, imageBindings : &&opt.ImageBinding, params_ : &opaque)

		-- two-loop recursion: http://papers.nips.cc/paper/5333-large-scale-l-bfgs-using-mapreduce.pdf
		
		var pd = [&PlanData](data_)
		var params = [&double](params_)
		var dims = pd.dims

		var [vars.imagesAll] = [util.getImages(vars, imageBindings, dims)]

		-- TODO: parameterize these
		var lineSearchMaxIters = 1000
		var lineSearchBruteForceStart = 1e-3
		var lineSearchBruteForceMultiplier = 1.1
		
		var m = 10
		var k = 0
		
		var prevBestAlpha = 0.0
		
		computeGradient(pd.gradient, vars.imagesAll)

		for iter = 0, maxIters - 1 do

			var iterStartCost = computeCost(vars.imagesAll)
			log("iteration %d, cost=%f\n", iter, iterStartCost)
			
			--
			-- compute the search direction p
			--
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					pd.p(w, h) = -pd.gradient(w, h)
				end
			end
			
			if k >= 1 then
				for i = k - 1, k - m - 1, -1 do
					if i < 0 then break end
					pd.alphaList[i] = imageInnerProduct(pd.sList[i], pd.p) / pd.syProduct[i]
					for h = 0, pd.gradH do
						for w = 0, pd.gradW do
							pd.p(w, h) = pd.p(w, h) - pd.alphaList[i] * pd.yList[i](w, h)
						end
					end
				end
				var scale = pd.syProduct[k - 1] / pd.yyProduct[k - 1]
				for h = 0, pd.gradH do
					for w = 0, pd.gradW do
						pd.p(w, h) = pd.p(w, h) * scale
					end
				end
				for i = k - m, k do
					if i >= 0 then
						var beta = imageInnerProduct(pd.yList[i], pd.p) / pd.syProduct[i]
						for h = 0, pd.gradH do
							for w = 0, pd.gradW do
								pd.p(w, h) = pd.p(w, h) + (pd.alphaList[i] - beta) * pd.sList[i](w, h)
							end
						end
					end
				end
			end
			
			C.memcpy(pd.currentValues.impl.data, vars.unknownImage.impl.data, sizeof(float) * pd.gradW * pd.gradH)
			
			--
			-- line search
			--
			computeResiduals(pd.currentValues, pd.currentResiduals, vars.dataImages)
			
			-- NOTE: this approach to line search will have unexpected behavior if the cost function
			-- returns double-precision, but residuals are stored at single precision!
			
			var bestAlpha = 0.0
			
			var useBruteForce = true
			--var useBruteForce = (iter <= 1) or prevBestAlpha == 0.0
			if not useBruteForce then
				var alphas = array(prevBestAlpha * 0.25, prevBestAlpha * 0.5, prevBestAlpha * 0.75, 0.0)
				var costs : float[4]
				var bestCost = 0.0
				
				for alphaIndex = 0, 3 do
					var alpha = 0.0
					if alphaIndex <= 2 then alpha = alphas[alphaIndex]
					else
						var a1 = alphas[0] var a2 = alphas[1] var a3 = alphas[2]
						var c1 = costs[0] var c2 = costs[1] var c3 = costs[2]
						var a = ((c2-c1)*(a1-a3) + (c3-c1)*(a2-a1))/((a1-a3)*(a2*a2-a1*a1) + (a2-a1)*(a3*a3-a1*a1))
						var b = ((c2 - c1) - a * (a2*a2 - a1*a1)) / (a2 - a1)
						var c = c1 - a * a1 * a1 - b * a1
						-- 2ax + b = 0, x = -b / 2a
						alpha = -b / (2.0 * a)
					end
					
					var searchCost = computeSearchCost(pd.currentValues, pd.currentResiduals, pd.p, alpha, vars.unknownImage, vars.dataImages)
					
					if searchCost < bestCost then
						bestAlpha = alpha
						bestCost = searchCost
					elseif alphaIndex == 3 then
						log("quadratic minimization failed\n")
						
						--[[var file = C.fopen("C:/code/debug.txt", "wb")

						var debugAlpha = lineSearchBruteForceStart
						for lineSearchIndex = 0, 400 do
							debugAlpha = debugAlpha * lineSearchBruteForceMultiplier
							
							var searchCost = computeSearchCost(pd.currentValues, pd.currentResiduals, pd.p, debugAlpha, vars.unknownImage, vars.dataImages)
							
							C.fprintf(file, "%15.15f\t%15.15f\n", debugAlpha * 1000.0, searchCost)
						end
						
						C.fclose(file)
						log("debug alpha outputted")
						C.getchar()]]
					end
					
					costs[alphaIndex] = searchCost
				end
				if bestAlpha == 0.0 then useBruteForce = true end
			end
			
			if useBruteForce then
				log("brute-force line search\n")
				var alpha = lineSearchBruteForceStart
				
				var bestCost = 0.0
				
				for lineSearchIndex = 0, lineSearchMaxIters do
					alpha = alpha * lineSearchBruteForceMultiplier
					
					var searchCost = computeSearchCost(pd.currentValues, pd.currentResiduals, pd.p, alpha, vars.unknownImage, vars.dataImages)
					
					--C.fprintf(file, "%f\t%f\n", alpha * 1000.0, searchCost / 1000000.0)
					
					if searchCost < bestCost then
						bestAlpha = alpha
						bestCost = searchCost
					else
						--break
					end
				end
			end
			
			-- compute new x and s
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					var delta = bestAlpha * pd.p(w, h)
					vars.unknownImage(w, h) = pd.currentValues(w, h) + delta
					pd.sList[k](w, h) = delta
				end
			end
			
			C.memcpy(pd.prevGradient.impl.data, pd.gradient.impl.data, sizeof(float) * pd.gradW * pd.gradH)
			
			computeGradient(pd.gradient, vars.imagesAll)
			
			-- compute new y
			for h = 0, pd.gradH do
				for w = 0, pd.gradW do
					pd.yList[k](w, h) = pd.gradient(w, h) - pd.prevGradient(w, h)
				end
			end
			
			pd.syProduct[k] = imageInnerProduct(pd.sList[k], pd.yList[k])
			pd.yyProduct[k] = imageInnerProduct(pd.yList[k], pd.yList[k])
			
			prevBestAlpha = bestAlpha
			
			k = k + 1
			
			log("alpha=%12.12f\n\n", bestAlpha)
			if bestAlpha == 0.0 then
				break
			end
		end
	end
	
	local terra makePlan(actualDims : &uint64) : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl
		pd.dims[0] = 1
		for i = 0,[#vars.dims] do
			pd.dims[i+1] = actualDims[i]
		end

		pd.gradW = pd.dims[vars.gradWIndex]
		pd.gradH = pd.dims[vars.gradHIndex]
		
		pd.costW = pd.dims[vars.costWIndex]
		pd.costH = pd.dims[vars.costHIndex]

		pd.gradient:initCPU(pd.gradW, pd.gradH)
		pd.prevGradient:initCPU(pd.gradW, pd.gradH)
		
		pd.currentValues:initCPU(pd.gradW, pd.gradH)
		pd.currentResiduals:initCPU(pd.costW, pd.costH)
		
		pd.p:initCPU(pd.gradW, pd.gradH)
		
		for i = 0, maxIters - 1 do
			pd.sList[i]:initCPU(pd.gradW, pd.gradH)
			pd.yList[i]:initCPU(pd.gradW, pd.gradH)
		end

		return &pd.plan
	end
	return Problem:new { makePlan = makePlan }
end

return solversCPU