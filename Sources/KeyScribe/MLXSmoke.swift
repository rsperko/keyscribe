import Foundation
import MLX

// argmax is compiled ahead of time into the shader library (the JIT covers most other ops), so this proves
// the library ships kernels, not just that it loads.
enum MLXSmoke {
    static func run() -> Int32 {
        guard let library = MLXShaderLibrary.liveSelection() else {
            print("mlx-smoke: no loadable shader library. Searched:")
            for url in MLXShaderLibrary.liveCandidates { print("  \(url.path)") }
            return 1
        }
        print("mlx-smoke: shader library \(library.path)")
        let values = MLXArray([1, 5, 3] as [Float])
        let doubled = values + values
        let index = argMax(values)
        eval(doubled, index)
        let sums = doubled.asArray(Float.self)
        let argmax = index.asType(.int32).item(Int32.self)
        guard sums == [2, 10, 6], argmax == 1 else {
            print("mlx-smoke: wrong result (sums \(sums), argmax \(argmax))")
            return 1
        }
        print("mlx-smoke ok")
        return 0
    }
}
