/*
 
 Main.
 
 Overall code structure of other files:

 - runNetwork - main inference loop

 - model - computations like rmsnorm, also definitions of Vector/Matrix class

 - loader - holds layer information and loads it up
 
 - bucketMul - main multiplication algorithm
 
 - convert - converts from .safetensors into the bucketized version.
             you'll probably better off just getting the bucketed weights from HF
 
 */


import os
import Foundation
import Metal
import simd

/*
 
 A ton of hotfixes went here last minute, needs to be refactored.
 
 Especially the parameter handling.
 
 Should be readable though.
 
 */

var serverReady = false
let gpu = Gpu()
print("\nEffort Engine v.0.0.1 BETA")

//runConvert([.mistral, .fp16])
// ^ uncomment to run conversion for other models.
//   be sure to check the convert script comments before

let args = CommandLine.arguments

/*
 
 below should be refactored into a Conf class.
 Need to do it smartly though, because during testing of larger models you want to easily
 be able to load fewer layers / fewer experts to pass by tests
 
 */

let stateDim = 4096
let hiddenDim = 14336
let goQ8 = false
assert(!goQ8, "Q8 not implemented fully yet!")
var percentLoad = goQ8 ? 0x8 : 0x10
                  // a number from 0x00 to 0x10 for FP16, or 0x0 to 0x8.
                  // not really percent, need to make design decision here - either switch to real percent
                  // or stick with the current convention but make it clear why.

let bSize: Int

var numLayers = 32
var numExperts = 1
var numTokens = 30

let goNoMuls = false
let goMistral = numExperts == 1
let goVerify = numLayers == 10 && ((numExperts == 2 && !goNoMuls && !goMistral) || goMistral)
let goSaveTests = false
var quickStart = false

// arg handling needs to be refactored

if args.count > 1 && args[1] == "quickstart" {
    quickStart = true
}
if args.count > 1 && args[1] == "playground" {
    goPlayground()
    exit(0)
}

ensureDirectoryExists(for: "./", createDirectoryAtPath: "models")
ensureDirectoryExists(for: "./models/", createDirectoryAtPath: "mistral")

let modelIndex = "./models/mistral/buckets-FP16.safetensors.index.json"
if !FileManager.default.fileExists(atPath: modelIndex) {
    print("\nModel data not found at \(modelIndex)")
    print("\nIf running from XCode and you have the model already:\n>>>   edit scheme -> working directory -> project directory\n")
    print("If running from terminal:")
    print(">>>  huggingface-cli download kolinko/mistral-buckets --exclude \"*Q8*\" --local-dir ./models/mistral")
    print("")
    print("If you don't have huggingface CLI:")
    print(">>>  pip install -U \"huggingface_hub[cli]\"")
    print()
    exit(0)
}


let physicalMemoryGB = ProcessInfo.processInfo.physicalMemory / 1024 / 1024 / 1024
print("Physical Memory: \(physicalMemoryGB) GB")

if physicalMemoryGB <= 8 {
    print("\nWhat is this? A computer for ants?\n\nI'll load just 37% of weights, the answers will be barely understandable.")
    print("Q8 is in the works and it will require just half the mem and give ~twice the speed, hopefully.\n")
    print("Press Enter to continue")
    _ = readLine()
    percentLoad = 0xB
} else if physicalMemoryGB <= 16 {
    print("\nAw! You're a bit short on memory.\nI'll load just 75% of the model, ok? Quality will suffer, but it should run without swap then.")
    print("Q8 is in the works and it will require just half the mem and give ~twice the speed, hopefully.\n")
    print("Press Enter to continue")
    _ = readLine()
    percentLoad = 0xB
}


let modelData = Model(numLayers: numLayers, numExperts: numExperts, percentLoad: percentLoad)
let t = Tokeniser(modelData)
if !quickStart && (args.count <= 1 || args[1] != "--no-benchmark") {
    goQuickBucketPerformance()
}

let headDim = 128  // Example head dimension
let numHeadsKV = 8
let numHeads = 32
let kvRepeats : Int = numHeads/numHeadsKV
let maxSeqLen = 2048
let maxTokens = maxSeqLen
let freqsCis = createFreqsCis2(headDim: headDim, maxSeqLen: maxSeqLen)

print()
if !quickStart {
    print("»»» How are ", terminator: "")
    _ = runNetwork(tokens: t.embed([1, 1602, 460]), effort:1.0)
}
// ^ fun fact, I noticed the message generated gets a bit more depressing as you decrease percentload and effort.
//   research needed if this is a true correlation.

numTokens = 150

var storedIntegers: [Int] = []
var storedStrings: [String] = []

var effort: Double = 1.0

serverReady = false
var isTest = false
var prevQuery : String? = nil

var modeABC = false


//let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "playground":
    goPlayground()
case "quiz":
    goQuiz()
case "benchmark":
    goBenchmarkSimilarity()
case "bucket":
    goBucketPerformance()
default:
    break
}

while true {
    print("This is a test environment. Doesn't hold context!")
    print("Enter 0-100 to change Effort, or type in query to see the output.")
    while true {
        print("> ", terminator: "")
        if let input = readLine() {
            if let number = Int(input), (0...100).contains(number) {
                effort = Double(number)/100.0
                if prevQuery != nil {
                    let tokens = t.embed("<s>[INST]\(prevQuery!)[/INST]")
                    _ = runNetwork(tokens: tokens, effort:effort)
                }
            } else if input == "r" {
                // a nice simple test case
                let tq = "What's larger - Radom, Poland, or Sydney, Australia?"
                print("? \(tq)")
                let tokens = t.embed("<s>[INST]\(tq)[/INST]")
                _ = runNetwork(tokens: tokens, effort:effort, srcTokenIds: encode(prompt:"<s>[INST]\(tq)[/INST]"))
            } else if input == "t" {
                isTest = !isTest
                print("Test switched to " + (isTest ? "ON" : "OFF"))
            } else if input == "a" {
                modeABC = !modeABC
                print(modeABC ? "Mode: question ABC" : "Mode: regular")
            } else if input == "w" {
                let tokens = t.embed([    1,   733, 16289, 28793,  1602,   460,   368, 28804,   733, 28748,
                                          16289, 28793])
                _ = runNetwork(tokens: tokens, effort:effort)
            } else if modeABC {
                testABCD(input)
            } else {
                prevQuery = input
                let tokens = t.embed("<s>[INST]"+input+"[/INST]")
                _ = runNetwork(tokens: tokens, effort:effort)
            }
        }
    }
}
