//
//  main.swift
//  mul_col
//
//  Created by Tomasz Kolinko on 24/01/2024.
//

import Foundation
import Metal

let devices = MTLCopyAllDevices()
assert(!devices.isEmpty, "No Metal devices available")

// Optionally, you can choose a device based on specific criteria.
// For simplicity, let's use the first available device.
let device = devices[0]

print("loading")
let modelData = loadModelData(from: "shape.json", device: device)
let tokens = loadTokens(device: device)

print("Hello, World!")

let commandQueue = device.makeCommandQueue()!
let library = device.makeDefaultLibrary()!
//let computeFunction = library.makeFunction(name: "mul_col")!

let dim = 4096
let dim_range = 0...4095

let headDim = 128  // Example head dimension
let numHeads = 32
let maxSeqLen = 128  // Example maximum sequence length
let freqsCis = createFreqsCis(headDim: headDim, maxSeqLen: maxSeqLen)

let tokenNum = 0

var xkLayerTokenHead = [[[Layer]]]()
var xvLayerTokenHead = [[[Layer]]]()
var xqLayerTokenHead = [[[Layer]]]()

for _ in 0...3 {
    xkLayerTokenHead.append([[Layer]]())
    xvLayerTokenHead.append([[Layer]]())
    xqLayerTokenHead.append([[Layer]]())
}

let numTokens = 1
let startTime = Date()

let thisToken = 0

for layerNo in 0...3 { //modelData.layers {
    var h = tokens[thisToken]
    assert(h.test("h", mul: 100, val: [0.02, -0.01, 0.01, 0.02, -0.01]))
    
    let layer = modelData.layers[layerNo]!
    let wa = layer["attention_norm"]!
    let wq = layer["attention.wq"]!
    let wk = layer["attention.wk"]!
    let wv = layer["attention.wv"]!
    let wo = layer["attention.wo"]!
    
    let h_norm = h.rmsNorm()
    let xn = mul(vec: h_norm, by:wa)
    
    let xq = mul_col(vec: xn, by: wq)
    let xk = mul_col(vec: xn, by: wk)
    let xv = mul_col(vec: xn, by: wv)
    
    var xq_heads = reshape(vec: xq, newDimSize: headDim)
    var xk_heads = reshape(vec: xk, newDimSize: headDim)
    let xv_heads = reshape(vec: xv, newDimSize: headDim)
    
    for i in 0..<numHeads {
        xq_heads[i] = mul(layer: xq_heads[i], complexArray: freqsCis[tokenNum])
        xk_heads[i] = mul(layer: xk_heads[i], complexArray: freqsCis[tokenNum])
    }

    xkLayerTokenHead[layerNo].append(xk_heads)
    xvLayerTokenHead[layerNo].append(xv_heads)
    
    let xkTokenHeads = xkLayerTokenHead[layerNo]
    let xvTokenHeads = xvLayerTokenHead[layerNo]
    
    var scores = makeArray(dims: [numHeads, thisToken+1], value: Float16(-10000)) as! [[Float16]]
    
    assert(thisToken+1 == xkTokenHeads.count)
    for t2 in 0...thisToken {
        for headNo in 0..<numHeads {
            let sum = dot(xq_heads[headNo], xkTokenHeads[t2][headNo])
            scores[headNo][t2] = sum / sqrt(Float16(headDim))
        }
    }
    
    for headNo in 0..<numHeads {
        softmax(&scores[headNo])
    }
    
    var out = makeArray(dims: [numHeads, headDim], value: Float16(0.0)) as! [[Float16]]
    
    for headNo in 0..<numHeads {
        for i in 0..<headDim {
            var suma: Float16 = 0.0
            for tok2 in 0...thisToken {
                suma += scores[headNo][tok2] * xvTokenHeads[thisToken][headNo][i]
            }
            out[headNo][i] = suma
        }
    }
    
    // merge heads
    var output = [Float16]()

    for headNo in 0..<numHeads {
        for i in 0..<headDim {
            output.append(out[headNo][i])
        }
    }
    
    // ffn output
    let attnOutput = Layer(from: output, using: device)
    let attnFfn = mul_row(vec: attnOutput, by: wo)

    assert(h.test("h", mul:100, val:[0.02, -0.01, 0.01, 0.02, -0.01]))
    assert(attnFfn.test("attn", mul: 100, val:[-0.05, -0.02, -0.09, -0.07, -0.04]))
    
    add(dest: &h, by: attnFfn)
    assert(h.test("h", mul:100, val:[-0.03, -0.03, -0.07, -0.04, -0.05]))
    
    let h_norm2 = h.rmsNorm()
    assert(h_norm2.test("h_norm2", mul:100, val:[-0.74, -0.69, -1.71, -0.949, -1.246]))
    let wn = layer["ffn_norm"]!
    let w1 = layer["feed_forward.w1"]!
    let w2 = layer["feed_forward.w2"]!
    let w3 = layer["feed_forward.w3"]!

    let fxn = mul(vec: h_norm2, by:wn)
    assert(fxn.test("fxn", mul:100, val:[-0.04, -0.06, -0.14, -0.07, -0.09]))
    
    let fx1 = mul_col(vec: fxn, by: w1)
    let fx3 = mul_col(vec: fxn, by: w3)
    
    assert(fx1.test("fx1", mul:100, val:[-0.1, -0.05, -0.08, -0.13, 0.11]))
    
    //    x = ((x1 / (1.0 + np.exp(-x1))) * x3
    var x = [(Float16)]()
    assert(fx3.shape[0] == 11008)
    for i in 0..<fx3.shape[0] {
        let val: Double = Double(fx1[i])/(1+exp(Double(-fx1[i]))) * Double(fx3[i])
        x.append(Float16(val))
    }

    let fx = Layer(from: x, using: device)
    let fx2 = mul_row(vec:fx, by: w2)//weights:w2, by:fx)
    assert(fx2.test("fx2", mul:100, val:[-0.030, -0.09, 0.03, -0.05, 0.06])) // double-check with original!
    
    add(dest: &h, by: fx2)
    assert(h.test("h", mul:100, val:[-0.06,-0.12,-0.05,-0.09,0.01,-0.01,-0.07]))
    print("success!")
    let endTime = Date()
    print("compute time time \(endTime.timeIntervalSince(startTime)) seconds")

    exit(0)

}

print("done")
exit(0)
/*

*/
