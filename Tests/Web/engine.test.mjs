import test from 'node:test';
import assert from 'node:assert/strict';
import { WasiPreview1, WasiExit, WasmForceGraph } from '../../Web/engine.js';

function host(options) {
    const wasi = new WasiPreview1(options);
    wasi.memory = new WebAssembly.Memory({ initial: 2 });
    return wasi;
}
function exportsFixture() {
    const calls = [];
    const exports = Object.fromEntries(['reset', 'add_edge', 'start', 'configure', 'step', 'x', 'y', 'begin_drag', 'drag', 'end_drag', 'reheat'].map(name => [`fg_${name}`, (...args) => { calls.push([name, ...args]); return name === 'y' ? -args[0] : args[0] ?? 1; }]));
    return { exports, calls };
}

test('clock and empty argument/environment writes check bounds and use little endian', () => {
    const wasi = host({ performance: { now: () => 12.5 } });
    const api = wasi.imports;
    assert.equal(api.clock_time_get(1, 0n, 0), 0);
    assert.equal(wasi.view(0, 8).getBigUint64(0, true), 12500000n);
    assert.equal(api.clock_time_get(0, 0n, 0), 0);
    assert.equal(api.clock_time_get(9, 0n, 0), 28);
    assert.equal(api.clock_time_get(1, 0n, -1), 21);
    assert.equal(api.clock_res_get(1, 0), 0);
    assert.equal(api.clock_res_get(8, 0), 28);
    assert.equal(api.clock_res_get(0, 131072), 21);
    for (const name of ['args_sizes_get', 'environ_sizes_get']) {
        assert.equal(api[name](0, 4), 0);
        assert.equal(api[name](0, 131072), 21);
        assert.equal(wasi.view(0, 8).getBigUint64(0, true), 0n);
    }
    assert.equal(api.args_get(), 0);
    assert.equal(api.environ_get(), 0);
    assert.equal(new WasiPreview1().region(0, 0), null);
    assert.equal(wasi.region(0.5, 1), null);
    assert.equal(wasi.region(0, -1), null);
    wasi.memory.grow(1);
    assert.ok(wasi.region(131072, 1));
});

test('stdio validates all vectors before output and reports EOF on stdin', () => {
    const writes = [];
    const wasi = host({ write: (fd, bytes) => writes.push([fd, [...bytes]]) });
    const api = wasi.imports;
    wasi.view(0, 8).setUint32(0, 32, true);
    wasi.view(0, 8).setUint32(4, 3, true);
    wasi.region(32, 3).set([65, 66, 67]);
    assert.equal(api.fd_write(1, 0, 1, 16), 0);
    assert.deepEqual(writes, [[1, [65, 66, 67]]]);
    assert.equal(wasi.view(16, 4).getUint32(0, true), 3);
    assert.equal(api.fd_write(0, 0, 1, 16), 8);
    assert.equal(api.fd_write(2, 131072, 1, 16), 21);
    assert.equal(api.fd_write(2, 0, 1, 131072), 21);
    wasi.view(0, 8).setUint32(0, 131072, true);
    assert.equal(api.fd_write(2, 0, 1, 16), 21);
    assert.equal(writes.length, 1);
    assert.equal(api.fd_read(1, 0, 1, 16), 8);
    assert.equal(api.fd_read(0, 0, 1, 16), 21);
    assert.equal(api.fd_read(0, 0, 0, 16), 0);
    assert.equal(wasi.view(16, 4).getUint32(0, true), 0);
    assert.equal(api.fd_fdstat_get(1, 32), 0);
    assert.equal(wasi.region(32, 1)[0], 2);
    assert.equal(api.fd_fdstat_get(0, 32), 0);
    assert.equal(api.fd_fdstat_get(3, 32), 8);
    assert.equal(api.fd_fdstat_get(0, 131072), 21);
    assert.equal(api.fd_close(1), 0);
    assert.equal(api.fd_close(3), 8);
    assert.equal(api.fd_seek(1), 70);
    assert.equal(api.fd_seek(3), 8);
    assert.equal(api.fd_prestat_get(), 8);
    assert.equal(api.fd_prestat_dir_name(), 8);
    assert.equal(api.sched_yield(), 0);
    assert.throws(() => api.proc_exit(3), error => error instanceof WasiExit && error.code === 3);
});

test('randomness is chunked and never substituted', () => {
    const lengths = [];
    const wasi = host({ crypto: { getRandomValues(bytes) { lengths.push(bytes.length); bytes.fill(7); } } });
    assert.equal(wasi.imports.random_get(0, 70000), 0);
    assert.deepEqual(lengths, [65536, 4464]);
    assert.equal(wasi.region(69999, 1)[0], 7);
    assert.equal(wasi.imports.random_get(-1, 1), 21);
    assert.throws(() => host({ crypto: null }).imports.random_get(0, 1), /requires crypto/);
});

test('engine ABI and arguments are validated before mutation; positions reuse storage', () => {
    assert.throws(() => new WasmForceGraph({}), /fg_reset/);
    const { exports, calls } = exportsFixture();
    const engine = new WasmForceGraph(exports);
    for (const count of [-1, 1.5, NaN, 2147483648]) assert.throws(() => engine.reset(count, []), RangeError);
    assert.throws(() => engine.reset(2, null), TypeError);
    for (const edges of [[[0, 2]], [[0]], [null]]) assert.throws(() => engine.reset(2, edges), RangeError);
    assert.equal(calls.length, 0);
    engine.reset(2, [[0, 1]]);
    assert.deepEqual(calls.slice(0, 3), [['reset', 2], ['add_edge', 0, 1], ['start']]);
    assert.deepEqual([...engine.positions()], [0, -0, 1, -1]);
    assert.equal(engine.positions(), engine.positions());
    engine.configure({ repulsion: 1, linkDistance: 2, centerStrength: 3 });
    assert.throws(() => engine.configure({ repulsion: NaN }), TypeError);
    assert.throws(() => engine.beginDrag(2, 0, 0), RangeError);
    assert.throws(() => engine.drag(1, Infinity, 0), TypeError);
    engine.beginDrag(1, 2, 3);
    engine.drag(1, 4, 5);
    engine.endDrag(1); engine.reheat();
    assert.deepEqual(calls.filter(([name]) => ['begin_drag', 'drag', 'end_drag'].includes(name)), [['begin_drag', 1, 2, 3], ['drag', 1, 4, 5], ['end_drag', 1]]);
    assert.equal(engine.step(), true);
    exports.fg_step = () => 0;
    assert.equal(engine.step(), false);
    exports.fg_step = () => { throw new WebAssembly.RuntimeError('trap'); };
    assert.throws(() => engine.step(), /trap/);
});

test('loader fetch failures, invalid modules and missing ABI fail explicitly', async t => {
    const originalFetch = globalThis.fetch;
    t.after(() => { globalThis.fetch = originalFetch; });
    globalThis.fetch = async () => ({ ok: false, status: 404 });
    await assert.rejects(WasmForceGraph.load('demo.wasm'), /HTTP 404/);
    globalThis.fetch = async () => { throw new Error('offline'); };
    await assert.rejects(WasmForceGraph.load('demo.wasm'), /offline/);
    globalThis.fetch = async () => ({ ok: true, arrayBuffer: async () => new Uint8Array([1]) });
    await assert.rejects(WasmForceGraph.load('demo.wasm'), WebAssembly.CompileError);
    const emptyModule = new Uint8Array([0,97,115,109,1,0,0,0]);
    globalThis.fetch = async () => ({ ok: true, arrayBuffer: async () => emptyModule });
    await assert.rejects(WasmForceGraph.load('demo.wasm'), /fg_reset/);
    const wasi = new WasiPreview1();
    assert.equal(wasi.importsFor(await WebAssembly.compile(emptyModule)).wasi_snapshot_preview1, wasi.imports);
});

// Small real Wasm modules exercise import resolution and initialization without a toolchain.
function wasmFixture({ importName = 'proc_exit', initializer = '_initialize', exit = null, trap = false, memory = true, invalidInitializer = false } = {}) {
    const unsigned = value => { const bytes = []; do { let byte = value & 127; value >>>= 7; if (value) byte |= 128; bytes.push(byte); } while (value); return bytes; };
    const string = value => [...unsigned(value.length), ...Buffer.from(value)];
    const section = (id, bytes) => [id, ...unsigned(bytes.length), ...bytes];
    const names = ['fg_reset', 'fg_add_edge', 'fg_start', 'fg_configure', 'fg_step', 'fg_x', 'fg_y', 'fg_begin_drag', 'fg_drag', 'fg_end_drag', 'fg_reheat'];
    const exported = names.map(name => [...string(name), 0, 1]);
    exported.push([...string(initializer), invalidInitializer ? 2 : 0, invalidInitializer ? 0 : 2]);
    if (memory) exported.push([...string('memory'), 2, 0]);
    const initialization = trap ? [0, 0, 11] : exit === null ? [0, 11] : [0, 65, exit, 16, 0, 11];
    return new Uint8Array([
        0,97,115,109,1,0,0,0,
        ...section(1, [3, 96,1,127,0, 96,0,1,127, 96,0,0]),
        ...section(2, [1, ...string('wasi_snapshot_preview1'), ...string(importName), 0,0]),
        ...section(3, [2,1,2]),
        ...section(5, [1,0,1]),
        ...section(7, [exported.length, ...exported.flat()]),
        ...section(10, [2,4,0,65,1,11, ...unsigned(initialization.length), ...initialization]),
    ]);
}

test('real Wasm fixture initializes reactors and commands, propagates traps and rejects unknown imports', async t => {
    const originalFetch = globalThis.fetch;
    t.after(() => { globalThis.fetch = originalFetch; });
    async function load(options) {
        globalThis.fetch = async url => { assert.equal(url, 'fixture.wasm'); return { ok: true, arrayBuffer: async () => wasmFixture(options) }; };
        return WasmForceGraph.load('fixture.wasm');
    }
    assert.equal((await load({})).step(), true);
    assert.equal((await load({ initializer: '_start', exit: 0 })).step(), true);
    await assert.rejects(load({ exit: 3 }), error => error instanceof WasiExit && error.code === 3);
    await assert.rejects(load({ trap: true }), WebAssembly.RuntimeError);
    await assert.rejects(load({ memory: false }), /must export memory/);
    await assert.rejects(load({ invalidInitializer: true }), /Invalid Wasm initialization export/);
    await assert.rejects(load({ importName: 'unsupported' }), /Unsupported Wasm import: wasi_snapshot_preview1.unsupported/);
});

test('filesystem capabilities and polling fail explicitly', () => {
    const wasi = host();
    for (const [name, operation] of Object.entries(wasi.imports)) {
        if (name.startsWith('path_')) assert.equal(operation(), 76);
        if (['fd_fdstat_set_flags', 'fd_filestat_get', 'fd_filestat_set_size', 'fd_filestat_set_times', 'fd_pread', 'fd_readdir', 'fd_sync', 'fd_tell'].includes(name)) assert.equal(operation(), 8);
    }
    assert.equal(wasi.imports.poll_oneoff(), 52);
    assert.equal(wasi.imports.fd_write(1, 0, 0, 16), 0);
    wasi.view(0, 8).setUint32(0, 32, true);
    wasi.view(0, 8).setUint32(4, 1, true);
    assert.equal(wasi.imports.fd_write(1, 0, 1, 16), 0);
});

test('reset capacity and edge validation precede allocation and Wasm mutation', () => {
    const { exports, calls } = exportsFixture();
    const engine = new WasmForceGraph(exports);
    engine.reset(2, []);
    const originalPositions = engine.positions();
    calls.length = 0;
    const OriginalFloat64Array = globalThis.Float64Array;
    globalThis.Float64Array = class { constructor() { throw new Error('unexpected allocation'); } };
    try {
        assert.throws(() => engine.reset(1001, []), /between 0 and 1000/);
        assert.throws(() => engine.reset(2, Array(10001).fill([0, 1])), /exceed 10000/);
        assert.throws(() => engine.reset(2, [[0, 2]]), /Invalid edge/);
    } finally {
        globalThis.Float64Array = OriginalFloat64Array;
    }
    assert.equal(engine.nodeCount, 2);
    assert.equal(engine.positionBuffer, originalPositions);
    assert.deepEqual(calls, []);
    for (const index of [-1, 2, 0.5, NaN, '0']) {
        assert.throws(() => engine.drag(index, 1, 2), RangeError);
        assert.throws(() => engine.endDrag(index), RangeError);
    }
    assert.deepEqual(calls, []);
    engine.reset(1000, Array(10000).fill([0, 999]));
    assert.equal(engine.positions().length, 2000);
    assert.equal(calls.filter(([name]) => name === 'add_edge').length, 10000);
});

test('actual Swift binary keeps dragged node pinned, releases it, and settles 1000 finite nodes', { skip: !process.env.FORCEGRAPH_WASM }, async t => {
    const { readFile } = await import('node:fs/promises');
    const bytes = await readFile(process.env.FORCEGRAPH_WASM);
    const originalFetch = globalThis.fetch;
    t.after(() => { globalThis.fetch = originalFetch; });
    globalThis.fetch = async () => ({ ok: true, arrayBuffer: async () => bytes });
    const engine = await WasmForceGraph.load('actual.wasm');
    engine.reset(1000, Array.from({ length: 999 }, (_, index) => [index, index + 1]));
    engine.configure({ repulsion: 100, linkDistance: 30, centerStrength: 0.01 });
    const index = 37;
    const coordinates = () => [...engine.positions().slice(index * 2, index * 2 + 2)];
    engine.beginDrag(index, 100, 200);
    assert.deepEqual(coordinates(), [100, 200]);
    engine.drag(index, 321, -123);
    assert.deepEqual(coordinates(), [321, -123]);
    for (let tick = 0; tick < 20; tick++) {
        engine.step();
        assert.deepEqual(coordinates(), [321, -123]);
    }
    engine.endDrag(index);
    engine.step();
    assert.notDeepEqual(coordinates(), [321, -123], 'released node must respond to forces');
    let ticks = 0;
    while (engine.step() && ticks < 2000) ticks++;
    assert.ok(ticks < 2000, 'released simulation must settle');
    assert.equal(engine.step(), false);
    assert.equal(engine.positions().length, 2000);
    assert.ok(engine.positions().every(Number.isFinite));
    engine.reheat();
    assert.equal(engine.step(), true);
});

test('loader detects gzip bytes, decompresses modules, and explains missing browser support', async t => {
    const { gzipSync } = await import('node:zlib');
    const originalFetch = globalThis.fetch;
    const originalDecompressionStream = globalThis.DecompressionStream;
    t.after(() => {
        globalThis.fetch = originalFetch;
        globalThis.DecompressionStream = originalDecompressionStream;
    });
    const compressed = gzipSync(wasmFixture());
    globalThis.fetch = async () => ({ ok: true, arrayBuffer: async () => compressed });
    assert.equal((await WasmForceGraph.load('forcegraph.wasm.gz')).step(), true);
    globalThis.DecompressionStream = undefined;
    await assert.rejects(WasmForceGraph.load('forcegraph.wasm.gz'), /requires browser DecompressionStream support/);
    globalThis.fetch = async () => ({ ok: true, arrayBuffer: async () => wasmFixture() });
    assert.equal((await WasmForceGraph.load('plain.wasm')).step(), true);
    globalThis.DecompressionStream = originalDecompressionStream;
    globalThis.fetch = async () => ({ ok: true, arrayBuffer: async () => new Uint8Array([0x1f, 0x8b, 0]) });
    await assert.rejects(WasmForceGraph.load('corrupt.wasm.gz'));
});
