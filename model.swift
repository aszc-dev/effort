import Foundation
import Metal

extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: Double, precision: Int) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX") // Use a locale with '.' as the decimal separator
        formatter.minimumFractionDigits = precision
        formatter.maximumFractionDigits = precision
        if let formattedString = formatter.string(for: value) {
            appendLiteral(formattedString)
        }
    }
}

struct Layer {
    let shape: [Int]
    let buffer: MTLBuffer
    let bufferPointer: UnsafeMutablePointer<Float16>
    let rows: Int
    let cols: Int?
    
    init(shape: [Int], device: MTLDevice) {
        let numElements = shape.reduce(1, *)
        let bufferSize = numElements * MemoryLayout<Float16>.size
        let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)!
        self.init(shape: shape, buffer: buffer)
    }

    init(shape: [Int], device: MTLDevice, andPrivate: Bool) {
        assert(andPrivate == true)
        let numElements = shape.reduce(1, *)
        let bufferSize = numElements * MemoryLayout<Float16>.size
        let buffer = device.makeBuffer(length: bufferSize, options: .storageModePrivate)!
        self.rows = shape[0]
        self.cols = shape.count >= 2 ? shape[1] : nil
        self.shape = shape
        self.buffer = buffer
        
        let bsBuffer = device.makeBuffer(length: 1, options: .storageModeShared)!
        self.bufferPointer = bsBuffer.contents().bindMemory(to: Float16.self, capacity: self.shape.reduce(1, *))
//        self.init(shape: shape, buffer: buffer)
    }

    
    init(shape: [Int], with: Float16, device: MTLDevice) {
        self.init(shape: shape, device: device)
        for i in 0..<self.count() {
            self[i] = with
        }
    }
    
    init(shape: [Int], buffer: MTLBuffer) {
        self.rows = shape[0]
        self.cols = shape.count >= 2 ? shape[1] : nil
        self.shape = shape
        self.buffer = buffer
        self.bufferPointer = buffer.contents().bindMemory(to: Float16.self, capacity: self.shape.reduce(1, *))
    }
    
    init(from array: [Float16], using device: MTLDevice) {
        assert(!array.isEmpty, "Array must not be empty")
        let length = array.count * MemoryLayout<Float16>.size
        let buffer = device.makeBuffer(bytes: array, length: length, options: .storageModeShared)!
        self.init(shape: [array.count], buffer: buffer)
    }
        
    func count() -> Int {
        return self.shape.reduce(1, *)
    }
    
    func rmsNorm() -> Layer {
        let layer = self
        assert(layer.shape.count == 1, "Only for vectors")
        
        let output = Layer(shape: layer.shape, device: layer.buffer.device)

        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

        let rmsBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: [])!
        let rmsBufferPointer = rmsBuffer.contents().bindMemory(to: Float.self, capacity: 1)
        rmsBufferPointer[0] = 0.0
        
        // Sum of squares
        let sumFunc = library.makeFunction(name: "sum_of_squares")!
        let sumState = try! device.makeComputePipelineState(function: sumFunc)
        
        //        var rms : Float = 0
        encoder.setComputePipelineState(sumState)
        encoder.setBuffer(layer.buffer, offset: 0, index: 0)
        encoder.setBuffer(rmsBuffer, offset: 0, index: 1)
        dispatch(encoder, state: sumState, threadCount: layer.count())
        
        // Normalize
        let normFunc = library.makeFunction(name: "normalize_vector")!
        let normState = try! device.makeComputePipelineState(function: normFunc)

        encoder.setComputePipelineState(normState)
        encoder.setBuffer(layer.buffer, offset: 0, index: 0)
        encoder.setBuffer(output.buffer, offset:0, index: 1)
        encoder.setBuffer(rmsBuffer, offset: 0, index: 2)
        var co: Int = self.count()
        encoder.setBytes(&co, length: 4, index: 3)

        dispatch(encoder, state: normState, threadCount: layer.count())
        // execute
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return output
    }
    
    func getInt(index: Int) -> Int16 {
        var floatStorage: Float16 = self[index]//1.0
        //        let floatValue: Float16 = w1ids[i]//1.0
        // Convert Float16 to UInt16 to preserve the bit pattern.
        withUnsafePointer(to: &floatStorage) { floatPointer in
            floatPointer.withMemoryRebound(to: Int16.self, capacity: 1) { intPointer in
                intStorage = intPointer.pointee
            }
        }
        return intStorage
    }

    
    subscript(index: Int) -> Float16 {
            get {
                let bufferPointer = self.bufferPointer
                return bufferPointer[index]
            }
            set(newValue) {
                let bufferPointer = self.bufferPointer
                bufferPointer[index] = newValue
            }
        }
    
    func test(_ name: String, mul:Int, val:[Float16]) -> Bool {
//        return true
        let result = self.test(mul: mul, val: val)
        if result {
//            print("✔️ \(name)")
        } else {
            print("❌ \(name)")
        }
        return result
    }
        
    func test(mul:Int, val:[Float16]) -> Bool {
        for i in 0..<val.count {
            if round(self[i]*Float16(mul)) != round(val[i]*Float16(mul)) {
                print("assert failed for values")
                for j in 0..<val.count {
                    print(self[j])
                }
                print("assert failed, on pos \(i), \(self[i]) ≠ \(val[i])")
                return false
            }
        }
        return true
    }
    
    func testInt(_ name: String, val:[Int16]) -> Bool {
        let result = self.testInt(val: val)
        if result {
            print("✔️ \(name)")
        } else {
            print("❌ \(name)")
        }
        return result
    }
        
    func testInt(val:[Int16]) -> Bool {
        for i in 0..<val.count {
            if (self.getInt(index: i) != val[i]) {
                print("assert failed for values")
                for j in 0..<val.count {
                    print(self.getInt(index:j))
                }
                print("assert failed, on pos \(i), \(self.getInt(index: i)) ≠ \(val[i])")
                return false
            }
        }
        return true
    }
    
    
}

/*
 
 array funcs
 
 */


func makeArray<T>(dims: [Int], value: T) -> Any {
    guard !dims.isEmpty else { return value }
    return Array(repeating: makeArray(dims: Array(dims.dropFirst()), value: value), count: dims.first!)
}


func softmax(_ array: inout [Float16]) {
    let layer = Layer(from: array, using: device)
//    let layer = self
    assert(layer.shape.count == 1, "Only for vectors")
    
    let output = Layer(shape: layer.shape, device: layer.buffer.device)
    
    let commandBuffer = commandQueue.makeCommandBuffer()!
    let encoder = commandBuffer.makeComputeCommandEncoder()!

    let rmsBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: [])!
    let rmsBufferPointer = rmsBuffer.contents().bindMemory(to: Float.self, capacity: 1)
    rmsBufferPointer[0] = 0.0
    
    // Sum of squares
    let sumFunc = library.makeFunction(name: "sum_of_exps")!
    let sumState = try! device.makeComputePipelineState(function: sumFunc)
    
    //        var rms : Float = 0
    encoder.setComputePipelineState(sumState)
    encoder.setBuffer(layer.buffer, offset: 0, index: 0)
    encoder.setBuffer(rmsBuffer, offset: 0, index: 1)
    dispatch(encoder, state: sumState, threadCount: layer.count())
    
    // Normalize
    let normFunc = library.makeFunction(name: "softmax_add")!
    let normState = try! device.makeComputePipelineState(function: normFunc)

    encoder.setComputePipelineState(normState)
    encoder.setBuffer(layer.buffer, offset: 0, index: 0)
    encoder.setBuffer(output.buffer, offset:0, index: 1)
    encoder.setBuffer(rmsBuffer, offset: 0, index: 2)

    dispatch(encoder, state: normState, threadCount: layer.count())
    // execute
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    for i in 0..<output.count() {
        array[i] = output[i]
    }
                
    
    return
    
  
    
    // Compute exponentials and sum them up
    let exps = array.map { Float16(exp(Float($0))) }
    let sumExps = exps.reduce(Float16(0.0), +)

    print("!")
    print(sumExps)
    
    print(array.count)
    // Normalize each element
    for i in array.indices {
        array[i] = exps[i] / sumExps
        if i < 10 {
            print(i)
            print(array[i])
        }
    }
    exit(0)
//    print(array[0])
//    print(array[1])
//    print(array[2])
}

func dot(_ vec1: Layer, _ vec2: Layer) -> Float16 {
    assert(vec1.count() == vec2.count(), "Vectors must be of the same length")
    
    var sum: Float16 = 0.0
    for i in 0..<vec1.count() {
        sum += vec1[i] * vec2[i]
    }
    return sum
}


/// freqs

func createFreqsCis(headDim: Int, maxSeqLen: Int) -> [[(Float16, Float16)]] {
    func logspace(start: Double, end: Double, num: Int, base: Double = 10.0) -> [Double] {
        assert(num>1)
        let step = (end - start) / Double(num)
        return (0..<num).map { pow(base, start + Double($0) * step) }
    }

    assert(headDim==128, "unusual headDim. it should work with others, but asserts/tests will fail")
    let freqs = logspace(start: 0, end: 1.0, num: headDim / 2, base: 1e-4)
    assert(freqs[2] == 0.7498942093324559)
    let def: (Float16, Float16) = (0.0, 0.0)
    var heads = makeArray(dims: [2*maxSeqLen, freqs.count], value:def) as! [[(Float16, Float16)]]
    for i in 0..<(2 * maxSeqLen) {
        for j in 0..<freqs.count {
            let freq = freqs[j]
            let angle = Float(i) * Float(freq)
            let realPart = Float16(cos(angle))
            let imagPart = Float16(sin(angle))
            heads[i][j]=(realPart, imagPart)
        }
    }
    assert(heads[1][1]==((0.6479058, 0.7617204)))
    return heads
}

func reshape(vec: Layer, newDimSize: Int) -> [Layer] {
    // Ensure that the original layer can be evenly divided by the new dimension size
    assert(vec.shape[0] % newDimSize == 0, "Original layer size must be divisible by new dimension size")

    let numNewLayers = vec.shape[0] / newDimSize
    let vecBufferPointer = vec.buffer.contents().bindMemory(to: Float16.self, capacity: vec.shape[0])
    let device = vec.buffer.device

    var newLayers: [Layer] = []

    for i in 0..<numNewLayers {
        let newBuffer = device.makeBuffer(length: newDimSize * MemoryLayout<Float16>.size, options: .storageModeShared)!
        let newBufferPointer = newBuffer.contents().bindMemory(to: Float16.self, capacity: newDimSize)
        memcpy(newBufferPointer, vecBufferPointer + i * newDimSize, newDimSize * MemoryLayout<Float16>.size)
        newLayers.append(Layer(shape: [newDimSize], buffer: newBuffer))
    }

    assert(newLayers[3][0] == vec[3*newDimSize])
    
    return newLayers
}

func mul(layer: Layer, complexArray: [(Float16, Float16)]) -> Layer {
    // Ensure the layer has the correct number of elements
    
    func multiplyComplex(_ num1: (Float16, Float16), _ num2: (Float16, Float16)) -> (Float16, Float16) {
        let (a, b) = num1
        let (c, d) = num2
        return (a * c - b * d, a * d + b * c)
    }
    
    assert(layer.shape[0] == complexArray.count * 2, "Layer size must be twice the size of the complex array")

    let count = layer.shape[0] / 2
    let device = layer.buffer.device
    let resultBuffer = device.makeBuffer(length: layer.shape[0] * MemoryLayout<Float16>.size, options: .storageModeShared)!
    let resultBufferPointer = resultBuffer.contents().bindMemory(to: Float16.self, capacity: layer.shape[0])

    for i in 0..<count {
        let complexNum = (layer[2 * i], layer[2 * i + 1])
        let result = multiplyComplex(complexNum, complexArray[i])
        resultBufferPointer[2 * i] = result.0     // Real part
        resultBufferPointer[2 * i + 1] = result.1 // Imaginary part
    }

    return Layer(shape: [128], buffer: resultBuffer)
}

func add(dest: inout Layer, by vector: Layer) {
    assert(dest.shape == vector.shape, "Shapes of both layers must match")

    for i in 0..<dest.count() {
        dest[i] += vector[i]
    }
}



func mul(vec: Layer, by wa: Layer) -> Layer {
    assert(vec.shape == wa.shape)
    
    var output = Layer(shape: vec.shape, device: vec.buffer.device)
    
    // Perform element-wise multiplication
    for i in 0..<vec.count() {
        output[i] = vec[i] * wa[i]
    }
    
    return output
}

func dispatch(_ encoder: MTLComputeCommandEncoder, state: MTLComputePipelineState, threadCount: Int) {
    let gridSize = MTLSize(width: threadCount, height: 1, depth: 1)
    let threadGroupSize = MTLSize(width: state.threadExecutionWidth, height: 1, depth: 1)
    encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
}

func deploy(_ encoder: MTLComputeCommandEncoder, fname: String, buffers: [Layer], threadCount: Int) {
    let internalFunc = library.makeFunction(name: fname)!
    let internalState = try! device.makeComputePipelineState(function: internalFunc)
        
    let gridSize = MTLSize(width: threadCount, height: 1, depth: 1)
    let threadGroupSize = MTLSize(width: internalState.threadExecutionWidth, height: 1, depth: 1)

    encoder.setComputePipelineState(internalState)

    for i in 0..<buffers.count {
        encoder.setBuffer(buffers[i].buffer, offset: 0, index: i)
    }
    encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
}

func ffn(_ h: inout Layer, fxn: Layer, w1: Layer, w2: Layer, w3: Layer) {
    let innerDim = 11008
    assert(w1.shape==[11008, 4096])
    assert(w2.shape==[4096, 11008])
    assert(w3.shape==[11008, 4096])
    assert(fxn.shape==[4096])
    
    let fx = Layer(shape: [innerDim], device: device)//, andPrivate: true)
    let startTime = Date()
    
    let commandBuffer = commandQueue.makeCommandBuffer()!
    let encoder = commandBuffer.makeComputeCommandEncoder()!

    deploy(encoder, fname: "internal", buffers: [fxn, w1, w3, fx], threadCount: 11008)
    deploy(encoder, fname: "second", buffers: [w2, fx, h], threadCount: 4096)

    // execute
    encoder.endEncoding()
    commandBuffer.commit()


    print("Internal total2: \(1000*Date().timeIntervalSince(startTime), precision:2) ms")

    commandBuffer.waitUntilCompleted()

    print("Internal total: \(1000*Date().timeIntervalSince(startTime), precision:2) ms")
}


func mul_col(vec: Layer, by weights: Layer) -> Layer {
    assert(weights.cols == vec.rows, "Weights column count must match vec length")
    let (rows, cols) = (weights.rows, weights.cols!)
    let startTime = Date()

    let output = Layer(shape: [rows], device: weights.buffer.device)

    let commandBuffer = commandQueue.makeCommandBuffer()!
    let commandEncoder = commandBuffer.makeComputeCommandEncoder()!

    deploy(commandEncoder, fname: "mul_col_\(cols)", buffers:[weights, vec, output], threadCount: rows)

    commandEncoder.endEncoding()
    commandBuffer.commit()

    commandBuffer.waitUntilCompleted()

    print("Mul_\(cols) total: \(1000*Date().timeIntervalSince(startTime), precision:2) ms")
    
    return output
}

func mul_vm(v: Layer, layer: [String: Layer], name: String) {
    // name e.g. feed_forward.w1
    let weights = layer[name]!
    let rowIds = layer[name+".ids"]!
    let rowVals = layer[name+".vals"]!
    let (rows, cols) = (weights.rows, weights.cols!)
    assert (rowIds.cols == weights.rows)
    assert (rowIds.rows == weights.cols)
    
    print(weights.shape)
    print(rowIds.shape)
    print(rowVals.shape)

    let probes = 4096
    var o = Layer(shape: [probes], device: weights.buffer.device)
    for i in 0..<probes {
        o[i] = abs(v[i] * weights[i*weights.cols! + i])
    }
    
    assert(o.test(mul: 10000, val: [0.0006, 0.0012, 0.0032, 0.0005, 0.0006]))
        
    sortVec(&o)
    assert(o[4095]==0.02194)
    assert(o[4094]==0.01575)

    let quant = 0.16
    let q = Int(Double(probes)*(1-quant))
    var cutoff: Float16 = o[q]

    let commandBuffer = commandQueue.makeCommandBuffer()!
    let encoder = commandBuffer.makeComputeCommandEncoder()!

    let bufferSize = 11008 * MemoryLayout<Float>.stride
    let bufferX = weights.buffer.device.makeBuffer(length: bufferSize, options: .storageModeShared)!
    let bufferPointer = bufferX.contents().bindMemory(to: Float.self, capacity: 11008)

    let out = Layer(shape: [rowVals.cols!], with: 0, device: weights.buffer.device)
    
    let accumFunction = library.makeFunction(name: "accum")!
    let pipeline = try! device.makeComputePipelineState(function: accumFunction)
    let threadgroupsPerGrid = MTLSize(width: v.rows, height: 1, depth: 1)
    let threadsPerThreadgroup = MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
    
    let threadCount = v.rows
    let gridSize = MTLSize(width: threadCount, height: 1, depth: 1)
    let threadGroupSize = MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
    
    for i in 0..<11008 {
        bufferPointer[i] = 0
    }
        
    encoder.setComputePipelineState(pipeline)

    encoder.setBuffer(v.buffer, offset: 0, index: 0)
    encoder.setBuffer(rowIds.buffer, offset: 0, index: 1)
    encoder.setBuffer(rowVals.buffer, offset: 0, index: 2)
    encoder.setBuffer(bufferX, offset: 0, index: 3)
    encoder.setBytes(&cutoff, length: MemoryLayout<Float16>.stride, index: 4)

    encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)

    
    let startTime = Date()
    encoder.endEncoding()
    commandBuffer.commit()

    commandBuffer.waitUntilCompleted()
    //PROFILE
    print("YoloMMUL: \(1000*Date().timeIntervalSince(startTime), precision:2) ms")

    let dataPointer = bufferX.contents().assumingMemoryBound(to: Float.self)
    let dataBufferPointer = UnsafeMutableBufferPointer(start: dataPointer, count: 11008)
    let floatData = Array.init(dataBufferPointer)

    print("works?")
    print(cutoff)
    print("cutoff")

    for i in 0..<8 {
        print(rowIds.getInt(index:i))
//        print(rowVals[i])
    }

    
    for i in 0..<10 {
        print(floatData[i])
    }
    
    
    exit(0)
    
}

func sortVec(_ v: inout Layer) {
    // taken from https://developer.apple.com/forums/thread/674181
    //            https://github.com/tgymnich/MetalSort
    

    let device = MTLCreateSystemDefaultDevice()!
    let commandQueue = device.makeCommandQueue()!
    let library = device.makeDefaultLibrary()!
    let sortFunction = library.makeFunction(name: "basicBitonicSort")!
    let pipeline = try! device.makeComputePipelineState(function: sortFunction)

    let setRange = 0..<v.rows

    guard let logn = Int(exactly: log2(Double(v.rows))) else {
        fatalError("data.count is not a power of 2")
    }
    var floatDataBuffer = v.buffer
    floatDataBuffer.label = "floatDataBuffer"
    let threadgroupsPerGrid = MTLSize(width: v.rows, height: 1, depth: 1)
    let threadsPerThreadgroup = MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
    
    let commandBuffer = commandQueue.makeCommandBuffer()!

    let encoder = commandBuffer.makeComputeCommandEncoder()!
    let startTime = Date()

    for p in 0..<logn {
        for q in 0..<p+1 {
            var n1 = p
            var n2 = q

            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(floatDataBuffer, offset: 0, index: 0)
            encoder.setBytes(&n1, length: MemoryLayout<Float>.stride, index: 1)
            encoder.setBytes(&n2, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        }
    }
    
    encoder.endEncoding()

    commandBuffer.commit()

    commandBuffer.waitUntilCompleted()

    print("basicSort: \(1000*Date().timeIntervalSince(startTime), precision:2) ms")

    }
