import { loginProblem } from "./lib/logins.ts"

const problem = loginProblem(process.argv[2] ?? "", process.env)
if (problem) {
  console.log(problem)
  process.exit(1)
}
