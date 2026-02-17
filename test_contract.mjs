import { readFile } from 'fs/promises';

// Test the wasmexec contract:
// - Module exports `memory` and `run(input_ptr, input_len) -> i32`
// - Host writes input at 0x10000
// - run() returns ptr to [u32 LE output_len][output_bytes...]

async function testContract(path, input, expectedOutput) {
    const bytes = await readFile(path);
    const { instance } = await WebAssembly.instantiate(bytes);
    const { memory, run } = instance.exports;

    if (!memory) throw new Error(`${path}: no exported memory`);
    if (!run) throw new Error(`${path}: no exported run function`);

    // Write input at 0x10000
    const inputBytes = new TextEncoder().encode(input);
    const mem = new Uint8Array(memory.buffer);
    mem.set(inputBytes, 0x10000);

    // Call run
    const resultPtr = run(0x10000, inputBytes.length);

    // Read output: [u32 LE len][bytes...]
    const view = new DataView(memory.buffer);
    const outputLen = view.getUint32(resultPtr, true); // little-endian
    const outputBytes = new Uint8Array(memory.buffer, resultPtr + 4, outputLen);
    const output = new TextDecoder().decode(outputBytes);

    const pass = output === expectedOutput;
    const mark = pass ? '✓' : '✗';
    const suffix = pass ? '' : ` (expected "${expectedOutput}")`;
    console.log(`  ${mark} ${path}: "${input}" \u2192 "${output}"${suffix}`);
    if (!pass) process.exit(1);
}

console.log('\nTesting wasmexec contract compliance:\n');

await testContract('examples/echo.wasm', 'hello world', 'hello world');
await testContract('examples/echo.wasm', '', '');
await testContract('examples/echo.wasm', 'abc123!@#', 'abc123!@#');

await testContract('examples/upper.wasm', 'hello world', 'HELLO WORLD');
await testContract('examples/upper.wasm', 'Hello World!', 'HELLO WORLD!');
await testContract('examples/upper.wasm', 'ABC123', 'ABC123');
await testContract('examples/upper.wasm', '', '');

console.log('\n🎉 All contract tests passed!');
