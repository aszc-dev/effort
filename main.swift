//
//  main.swift
//  mul_col
//
//  Created by Tomasz Kolinko on 24/01/2024.
//

import Foundation
import Metal
import simd

let devices = MTLCopyAllDevices()
assert(!devices.isEmpty, "No Metal devices available")

// Optionally, you can choose a device based on specific criteria.
// For simplicity, let's use the first available device.
let device = devices[0]
let commandQueue = device.makeCommandQueue()!

print("loading")
let modelData = loadModelData(from: "shape.json", device: device)
let tokens = loadTokens(device: device)

assert(modelData.layers[0]!["feed_forward.w1.ids"]!.testInt("w1ids", val:[3260, 7938, 9263, 9670]))
assert(tokens[0].test("h", mul: 100, val: [0.02, -0.01, 0.01, 0.02, -0.01]))


print("Hello, World!")

let library = device.makeDefaultLibrary()!
let internalSFunc = library.makeFunction(name:"internal")!
let internalSState = try! device.makeComputePipelineState(function: internalSFunc)
let secondSFunc = library.makeFunction(name:"internal")!
let secondSState = try! device.makeComputePipelineState(function: secondSFunc)


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

import Foundation
import simd

// Example Float16 value
let floatValue: Float16 = 1.0

// Allocate memory for Float16 and write the value
var floatStorage = floatValue
var intStorage: Int16 = 0



for layerNo in 0...3 {
    var h = tokens[thisToken]
    let layer = modelData.layers[layerNo]!
    
    let wa = layer["attention_norm"]!
    
    let wq = layer["attention.wq"]!
    let wk = layer["attention.wk"]!
    let wv = layer["attention.wv"]!
    
    let wo = layer["attention.wo"]!
    
    print("compute time \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")
    let h_norm = h.rmsNorm()
    print("compute time rmsnorm \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    let h_norm_norm = mul(vec: h_norm, by:wa)
    print("compute time \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    let xq = mul_col(vec: h_norm_norm, by: wq)
    print(wq.shape)
    let xk = mul_col(vec: h_norm_norm, by: wk)
    let xv = mul_col(vec: h_norm_norm, by: wv)
    print("compute timen \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    var xq_heads = reshape(vec: xq, newDimSize: headDim)
    var xk_heads = reshape(vec: xk, newDimSize: headDim)
    let xv_heads = reshape(vec: xv, newDimSize: headDim)
    print("compute timen \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    for i in 0..<numHeads {
        xq_heads[i] = mul(layer: xq_heads[i], complexArray: freqsCis[tokenNum])
        xk_heads[i] = mul(layer: xk_heads[i], complexArray: freqsCis[tokenNum])
    }
    print("compute timen \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

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
    print("computen timen \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    for headNo in 0..<numHeads {
        softmax(&scores[headNo])
    }
    print("computen timen softmax \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    var out = makeArray(dims: [numHeads, headDim], value: Float16(0.0)) as! [[Float16]]
    print("computen timen \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    for headNo in 0..<numHeads {
        for i in 0..<headDim {
            var suma: Float16 = 0.0
            for tok2 in 0...thisToken {
                suma += scores[headNo][tok2] * xvTokenHeads[thisToken][headNo][i]
            }
            out[headNo][i] = suma
        }
    }
    print("computen timen \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    // merge heads
    var output = [Float16]()

    for headNo in 0..<numHeads {
        for i in 0..<headDim {
            output.append(out[headNo][i])
        }
    }
    
    // ffn output
    let attnOutput = Layer(from: output, using: device)
    let attnFfn = mul_col(vec: attnOutput, by: wo)
    print("compute time \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    assert(h.test("h", mul:100, val:[0.02, -0.01, 0.01, 0.02, -0.01]))
    assert(attnFfn.test("attn", mul: 100, val:[-0.05, -0.02, -0.09, -0.07, -0.04]))
    
    add(dest: &h, by: attnFfn)
    assert(h.test("h", mul:100, val:[-0.03, -0.03, -0.07, -0.04, -0.05]))
    print("compute time \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    let h_norm2 = h.rmsNorm()
    assert(h_norm2.test("h_norm2", mul:100, val:[-0.74, -0.69, -1.71, -0.949, -1.246]))
    let wn = layer["ffn_norm"]!
    let w1 = layer["feed_forward.w1"]!
    let w2 = layer["feed_forward.w2"]!
    let w3 = layer["feed_forward.w3"]!

    let fxn = mul(vec: h_norm2, by:wn)
    assert(fxn.test("fxn", mul:100, val:[-0.04, -0.06, -0.14, -0.07, -0.09]))
    print("compute timex \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    // below = 22.28-15.73 = 6ms = 1/4th of all the loop
    
    print(w1.shape)
//    mul_vm(v:fxn, layer:layer, name:"feed_forward.w1")

    
    ffn(&h, fxn:fxn, w1:w1, w2:w2, w3:w3)
    print("compute time \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    assert(h.test("h", mul:100, val:[-0.06,-0.12,-0.05,-0.09,0.01,-0.01,-0.07]))
    print("success!")

    print("compute time \(Date().timeIntervalSince(startTime)*1000, precision: 2) ms")

    exit(0)

}

print("done")
exit(0)
/*

*/
