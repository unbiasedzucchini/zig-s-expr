import { readFile } from 'fs/promises';

async function testModule(path, tests) {
    const bytes = await readFile(path);
    const { instance } = await WebAssembly.instantiate(bytes);
    console.log(`\n✓ ${path} loaded (${bytes.length} bytes)`);
    for (const [name, args, expected] of tests) {
        const result = instance.exports[name](...args);
        const pass = result === expected;
        const mark = pass ? '✓' : '✗';
        const suffix = pass ? '' : ` (expected ${expected})`;
        console.log(`  ${mark} ${name}(${args.join(', ')}) = ${result}${suffix}`);
        if (!pass) process.exit(1);
    }
}

await testModule('examples/add.wasm', [
    ['add', [2, 3], 5],
    ['add', [0, 0], 0],
    ['add', [-1, 1], 0],
    ['add', [100, 200], 300],
]);

await testModule('examples/factorial.wasm', [
    ['factorial', [0], 1],
    ['factorial', [1], 1],
    ['factorial', [5], 120],
    ['factorial', [10], 3628800],
]);

await testModule('examples/fibonacci.wasm', [
    ['fib', [0], 0],
    ['fib', [1], 1],
    ['fib', [2], 1],
    ['fib', [10], 55],
    ['fib', [20], 6765],
]);

await testModule('examples/demo.wasm', [
    ['abs', [5], 5],
    ['abs', [-5], 5],
    ['abs', [0], 0],
    ['max', [3, 7], 7],
    ['max', [7, 3], 7],
    ['min', [3, 7], 3],
    ['sum_to', [10], 55],
    ['sum_to', [100], 5050],
    ['is_prime', [2], 1],
    ['is_prime', [7], 1],
    ['is_prime', [4], 0],
    ['is_prime', [1], 0],
    ['is_prime', [97], 1],
    ['gcd', [12, 8], 4],
    ['gcd', [100, 75], 25],
    ['gcd', [17, 13], 1],
]);

console.log('\n\ud83c\udf89 All tests passed!');
