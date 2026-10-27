import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { WasiPreview1, WasiExit, WasmForceGraph } from '../../Web/engine.js';

const artifact = new URL('../../Web/forcegraph.wasm', import.meta.url);
let available = true;
try { await access(artifact); } catch { available = false; }

async function realEngine() {
    const module = await WebAssembly.compile(await readFile(artifact));
    const wasi = new WasiPreview1();
    const instance = await WebAssembly.instantiate(module, wasi.importsFor(module));
    wasi.memory = instance.exports.memory;
    try { instance.exports._start(); } catch (error) {
        if (!(error instanceof WasiExit) || error.code !== 0) throw error;
    }
    return new WasmForceGraph(instance.exports);
}

const forces = { repulsion: 180, linkDistance: 75, centerStrength: 0.015 };

test('compiled Swift Wasm agrees with the native Swift reference fixture', { skip: !available }, async () => {
    const engine = await realEngine();
    engine.reset(4, [[0, 1], [1, 2], [1, 3]]);
    engine.configure(forces);
    for (let tick = 0; tick < 30; tick++) engine.step();
    const expected = JSON.parse(await readFile(new URL('./native-reference.json', import.meta.url), 'utf8'));
    const actual = engine.positions();
    assert.equal(actual.length, expected.length);
    for (let index = 0; index < actual.length; index++) {
        // CGPoint uses 32-bit CGFloat on wasm32; the native fixture uses 64-bit CGFloat.
        assert.equal(actual[index], Math.fround(expected[index]), `coordinate ${index}: ${actual[index]} versus ${expected[index]}`);
    }
});

test('real Swift dragging holds exact coordinates, moves neighbours and settles after release', { skip: !available }, async () => {
    const engine = await realEngine();
    engine.reset(3, [[0, 1], [1, 2]]);
    engine.configure(forces);
    for (let tick = 0; tick < 30; tick++) engine.step();
    const neighbour = engine.positions()[2];
    engine.beginDrag(0, 50, 75);
    engine.drag(0, 200, 150);
    assert.equal(engine.positions()[0], 200);
    assert.equal(engine.positions()[1], 150);
    for (let tick = 0; tick < 30; tick++) assert.equal(engine.step(), true);
    assert.equal(engine.positions()[0], 200);
    assert.equal(engine.positions()[1], 150);
    assert.notEqual(engine.positions()[2], neighbour);
    engine.endDrag(0);
    let warm = true;
    for (let tick = 0; tick < 500 && warm; tick++) warm = engine.step();
    assert.equal(warm, false);
    assert.notEqual(engine.positions()[0], 200);
    assert.ok([...engine.positions()].every(Number.isFinite));
    engine.reheat();
    assert.equal(engine.step(), true);
});

test('a 1000-node browser graph stays finite and empty resets discard old coordinates', { skip: !available }, async t => {
    const engine = await realEngine();
    engine.reset(1000, Array.from({ length: 999 }, (_, index) => [index, index + 1]));
    engine.configure(forces);
    const start = performance.now();
    for (let tick = 0; tick < 30; tick++) engine.step();
    t.diagnostic(`1000 nodes, 30 Wasm steps: ${(performance.now() - start).toFixed(1)} ms`);
    assert.equal(engine.positions().length, 2000);
    assert.ok([...engine.positions()].every(Number.isFinite));
    engine.reset(0, []);
    assert.equal(engine.positions().length, 0);
});
