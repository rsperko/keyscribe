import Metal
import MLX

enum MLXSmoke {
    static func run(hasMetalDevice: Bool = MTLCreateSystemDefaultDevice() != nil) -> Int32 {
        guard hasMetalDevice else {
            print("mlx-smoke: no Metal device on this machine, so Qwen3-ASR can't run or be validated here")
            return 1
        }
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
