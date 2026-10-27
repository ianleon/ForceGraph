import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../../Web/demo.js', import.meta.url), 'utf8');

// Run the actual UI functions with a small browser boundary. No fake physics:
// engine calls are recorded; only the parent integration tests execute Wasm.
function playground({ reducedMotion = false, viewportWidth = 948, viewportHeight = 637 } = {}) {
    const elements = new Map();
    const captures = new Set();
    const drawingCalls = [];
    const drawing = new Proxy({}, { get: (_, name) => (...args) => drawingCalls.push([name, ...args]) });
    const rectangle = { top: 77, left: 0, width: viewportWidth, height: viewportHeight };
    function getElement(id) {
        if (!elements.has(id)) elements.set(id, {
            value: ({ preset: '42', repulsion: '180', distance: '75', center: '.015' })[id] ?? '',
            listeners: {},
            addEventListener(name, callback) { this.listeners[name] = callback; },
            setAttribute() {},
            classList: { toggle() {}, add() {}, remove() {} },
            getBoundingClientRect: () => rectangle,
            getContext: () => drawing,
            setPointerCapture: (id) => captures.add(id),
            hasPointerCapture: (id) => captures.has(id),
            releasePointerCapture: (id) => captures.delete(id),
        });
        return elements.get(id);
    }
    const windowListeners = {};
    const sandbox = vm.createContext({
        document: {
            getElementById: getElement,
            querySelector: (selector) => ({ getBoundingClientRect: () => selector === '.graph-heading' ? { bottom: 268 } : { top: rectangle.top + rectangle.height - 110 } }),
        },
        window: { devicePixelRatio: 1, addEventListener: (name, callback) => { windowListeners[name] = callback; } },
        matchMedia: () => ({ matches: reducedMotion }),
        requestAnimationFrame: () => 1,
        cancelAnimationFrame() {},
        ResizeObserver: class { observe() {} },
        console,
    });
    // Suppress asynchronous loading only; all tested functions remain unchanged.
    vm.runInContext(source.replaceAll('import.meta.url', "'https://example.test/demo.js'").replace(/loadEngine\(\);\s*$/, ''), sandbox);
    const run = (expression) => vm.runInContext(expression, sandbox);
    run(`globalThis.calls = []; engine = {
        reset: (...args) => calls.push(['reset', ...args]),
        configure: (...args) => calls.push(['configure', ...args]),
        positions: () => positions,
        reheat: () => calls.push(['reheat']),
        step: () => { calls.push(['step']); return false; },
        beginDrag: (...args) => calls.push(['beginDrag', ...args]),
        drag: (...args) => calls.push(['drag', ...args]),
        endDrag: (...args) => calls.push(['endDrag', ...args]),
    };`);
    const json = (expression) => JSON.parse(run(`JSON.stringify(${expression})`));
    const dispatch = (id, type, event = {}) => getElement(id).listeners[type](event);
    const pointer = (id, x, y) => ({ pointerId: id, clientX: x, clientY: y + rectangle.top, pointerType: 'touch', button: 0 });
    return { run, json, dispatch, pointer, captures, windowListeners, rectangle, drawingCalls };
}

function close(actual, expected) {
    assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} should equal ${expected}`);
}

test('presets generate deterministic connected networks with valid unique edges', () => {
    const app = playground();
    for (const count of [42, 100, 500, 1000]) {
        app.run(`createNetwork(${count})`);
        const { nodes, edges } = app.json('({ nodes, edges })');
        assert.equal(nodes.length, count);
        assert.ok(nodes.every((node) => node.name && node.group >= 0 && node.group <= 2));
        const keys = edges.map(([a, b]) => {
            assert.ok(a >= 0 && b >= 0 && a < count && b < count && a !== b);
            return [a, b].sort((x, y) => x - y).join(':');
        });
        assert.equal(new Set(keys).size, edges.length);
        const reached = new Set([0]);
        for (let pass = 0; pass < count; pass += 1) {
            for (const [a, b] of edges) {
                if (reached.has(a)) reached.add(b);
                if (reached.has(b)) reached.add(a);
            }
        }
        assert.equal(reached.size, count);
        app.run(`createNetwork(${count})`);
        assert.deepEqual(app.json('({ nodes, edges })'), { nodes, edges });
    }
});

test('fit keeps extreme positions inside the measured heading and toolbar margins', () => {
    const app = playground();
    const area = app.json('graphFitArea()');
    assert.equal(area.y, 217);
    assert.equal(area.y + area.height, 495);
    for (const points of [[-1000, -800, 2000, 900], [-1e7, 0, 1e7, 0], [0, 0]]) {
        app.run(`positions = new Float64Array(${JSON.stringify(points)}); updateFittedCamera()`);
        const camera = app.json('camera');
        for (let index = 0; index < points.length; index += 2) {
            const x = points[index] * camera.scale + camera.x;
            const y = points[index + 1] * camera.scale + camera.y;
            assert.ok(x >= area.x - 1e-8 && x <= area.x + area.width + 1e-8);
            assert.ok(y >= area.y - 1e-8 && y <= area.y + area.height + 1e-8);
        }
    }
    assert.equal(app.run('fittedCamera(new Float64Array(), graphFitArea())'), null);
    assert.equal(app.run('fittedCamera([NaN, Infinity], graphFitArea())'), null);
});

test('automatic fitting follows simulation growth and stops after user pan', () => {
    const app = playground();
    app.run('createNetwork(42); positions = new Float64Array(84); running = true; renderFrame()');
    const firstScale = app.run('camera.scale');
    app.run('positions[0] = 5000; running = true; renderFrame()');
    assert.ok(app.run('camera.scale') < firstScale);
    app.dispatch('graph', 'pointerdown', app.pointer(1, 900, 600));
    assert.equal(app.run('automaticFit'), false);
    const camera = app.json('camera');
    app.run('positions[0] = 9000; running = true; renderFrame()');
    assert.deepEqual(app.json('camera'), camera);
});

test('zoom preserves pointer world anchor including scale limits', () => {
    const app = playground();
    app.run('camera = { x: 50, y: 70, scale: 2 }');
    const anchor = app.json('worldPoint({ x: 240, y: 310 })');
    for (const factor of [1.4, 100, .00001]) {
        app.run(`zoomAt({ x: 240, y: 310 }, ${factor})`);
        const after = app.json('worldPoint({ x: 240, y: 310 })');
        close(after.x, anchor.x);
        close(after.y, anchor.y);
        assert.ok(app.run('camera.scale') >= .08 && app.run('camera.scale') <= 5);
    }
});

test('hit testing respects camera and chooses the last drawn overlapping node', () => {
    const app = playground();
    app.run('createNetwork(42); positions = new Float64Array(84).fill(10000); positions[0] = 10; positions[1] = 20; camera = { x: 50, y: 60, scale: 2 }');
    assert.equal(app.run('hitNode({ x: 70, y: 100 })'), 0);
    assert.equal(app.run('hitNode({ x: 0, y: 0 })'), -1);
    app.run('positions[82] = 10; positions[83] = 20');
    assert.equal(app.run('hitNode({ x: 70, y: 100 })'), 41);
});

test('paused dragging preserves grab offset without stepping physics; cancellation releases once', () => {
    const app = playground({ reducedMotion: true });
    app.run('createNetwork(42); positions = new Float64Array(84).fill(10000); positions[0] = 10; positions[1] = 20; camera = { x: 0, y: 0, scale: 2 }');
    app.dispatch('graph', 'pointerdown', app.pointer(1, 24, 44));
    app.dispatch('graph', 'pointermove', app.pointer(1, 64, 84));
    assert.deepEqual(app.json("calls.find(([name]) => name === 'drag')"), ['drag', 0, 30, 40]);
    app.run('renderFrame()');
    assert.equal(app.run("calls.filter(([name]) => name === 'step').length"), 0);
    app.dispatch('graph', 'pointercancel', app.pointer(1, 64, 84));
    app.dispatch('graph', 'lostpointercapture', app.pointer(1, 64, 84));
    assert.equal(app.run("calls.filter(([name]) => name === 'endDrag').length"), 1);
    assert.equal(app.run('gesture'), null);
    app.run('finishGesture()');
    app.captures.clear(); // Browsers release capture automatically on pointercancel.
    assert.equal(app.run('pointers.size'), 0);
    assert.equal(app.run('paused'), true);
});

test('second pointer cancels node dragging for pinch; blur releases captures', () => {
    const app = playground();
    app.run('createNetwork(42); positions = new Float64Array(84).fill(10000); positions[0] = 10; positions[1] = 20; camera = { x: 0, y: 0, scale: 1 }');
    app.dispatch('graph', 'pointerdown', app.pointer(1, 10, 20));
    app.dispatch('graph', 'pointerdown', app.pointer(2, 110, 20));
    assert.equal(app.run('gesture.type'), 'pinch');
    assert.equal(app.run("calls.filter(([name]) => name === 'endDrag').length"), 1);
    app.dispatch('graph', 'pointermove', app.pointer(2, 210, 20));
    close(app.run('camera.scale'), 2);
    app.windowListeners.blur();
    assert.equal(app.captures.size, 0);
    assert.equal(app.run('pointers.size'), 0);
    assert.equal(app.run('gesture'), null);
});

test('pause prevents stepping, resume steps, and settled frames stop scheduling', () => {
    const app = playground();
    app.run('positions = new Float64Array(); running = true');
    app.dispatch('pause', 'click');
    app.run('renderFrame()');
    assert.equal(app.run("calls.filter(([name]) => name === 'step').length"), 0);
    app.dispatch('pause', 'click');
    app.run('renderFrame()');
    assert.equal(app.run("calls.filter(([name]) => name === 'step').length"), 1);
    assert.equal(app.run('frame'), 0);
    assert.equal(app.run('running'), false);
});


test('mobile fit leaves heading and controls clear at narrow viewport sizes', () => {
    for (const viewportWidth of [320, 375, 760]) {
        const app = playground({ viewportWidth, viewportHeight: 480 });
        app.run('positions = new Float64Array([-800, -900, 1000, 700]); updateFittedCamera()');
        const area = app.json('graphFitArea()');
        const camera = app.json('camera');
        assert.ok(area.width > 0 && area.height > 0);
        for (const [x, y] of [[-800, -900], [1000, 700]]) {
            const screenX = x * camera.scale + camera.x;
            const screenY = y * camera.scale + camera.y;
            assert.ok(screenX >= area.x - 1e-8 && screenX <= area.x + area.width + 1e-8);
            assert.ok(screenY >= area.y - 1e-8 && screenY <= area.y + area.height + 1e-8);
        }
    }
});

test('blur ends an active drag once and clears pointer capture', () => {
    const app = playground();
    app.run('createNetwork(42); positions = new Float64Array(84).fill(10000); positions[0] = 10; positions[1] = 20; camera = { x: 0, y: 0, scale: 1 }');
    app.dispatch('graph', 'pointerdown', app.pointer(1, 10, 20));
    app.windowListeners.blur();
    app.windowListeners.blur();
    assert.equal(app.run("calls.filter(([name]) => name === 'endDrag').length"), 1);
    assert.equal(app.captures.size, 0);
    assert.equal(app.run('gesture'), null);
});


test('node radii, hub labels, and hit targets stay constant in screen points at fit zoom', () => {
    const app = playground();
    app.run('createNetwork(42); positions = new Float64Array(84).fill(10000); positions[0] = 0; positions[1] = 0; positions[2] = 200; positions[3] = 0');
    for (const scale of [.29, 1, 3]) {
        app.run(`camera = { x: 0, y: 0, scale: ${scale} }`);
        app.drawingCalls.length = 0;
        app.run('drawNode(nodes[0], 0); drawNode(nodes[1], 1)');
        const arcs = app.drawingCalls.filter(([name]) => name === 'arc');
        close(arcs[0][3] * scale, 7);
        close(arcs[1][3] * scale, 3.8);
        const labels = app.drawingCalls.filter(([name]) => name === 'fillText');
        assert.equal(labels.length, 1);
        assert.equal(labels[0][1], 'Curiosity');
        close(labels[0][3] * scale, 24);
        assert.equal(app.run('hitNode({ x: 15.9, y: 0 })'), 0);
        assert.equal(app.run('hitNode({ x: 16.1, y: 0 })'), -1);
        assert.equal(app.run(`hitNode({ x: ${200 * scale + 12.7}, y: 0 })`), 1);
        assert.equal(app.run(`hitNode({ x: ${200 * scale + 12.9}, y: 0 })`), -1);
    }
});
