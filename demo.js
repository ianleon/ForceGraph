const element = (id) => document.getElementById(id);
const canvas = element('graph');
const context = canvas.getContext('2d');
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const colors = ['#69deef', '#a59aff', '#e495d0'];
const categories = ['Explore', 'Create', 'Connect'];
const titles = ['Curiosity', 'Field notes', 'Small discoveries', 'Open questions', 'New perspectives', 'Patterns', 'Quiet moments', 'First principles', 'Possibilities', 'Shared ideas', 'Creative practice', 'Connections', 'Experiments', 'A fresh start'];
let engine;
let nodes = [];
let edges = [];
let positions = new Float64Array();
let paused = reducedMotion;
let running = false;
let frame = 0;
let selected = -1;
let width = 1;
let height = 1;
let camera = { x: 0, y: 0, scale: 1 };
const pointers = new Map();
let gesture = null;
let loading = false;
let automaticFit = true;

function createNetwork(count) {
    nodes = Array.from({ length: count }, (_, index) => ({
        name: `${titles[index % titles.length]}${index >= titles.length ? ` ${Math.floor(index / titles.length) + 1}` : ''}`,
        group: Math.floor(index / Math.ceil(count / 3)),
    }));
    edges = [];
    const existing = new Set();
    function connect(first, second) {
        if (first === second) return;
        const key = `${Math.min(first, second)}:${Math.max(first, second)}`;
        if (existing.has(key)) return;
        existing.add(key);
        edges.push([first, second]);
    }
    nodes.forEach((node, index) => {
        const groupStart = node.group * Math.ceil(count / 3);
        if (index > groupStart) connect(index, groupStart + Math.floor((index - groupStart - 1) / 2));
        if (index > groupStart + 2 && index % 3 === 0) connect(index, index - 2);
    });
    connect(0, Math.ceil(count / 3));
    connect(Math.ceil(count / 3), Math.ceil(count / 3) * 2);
    connect(Math.ceil(count / 3) * 2, 0);
}

function forceSettings() {
    return { repulsion: Number(element('repulsion').value), linkDistance: Number(element('distance').value), centerStrength: Number(element('center').value) };
}

function resetNetwork() {
    finishGesture();
    cancelAnimationFrame(frame);
    frame = 0;
    createNetwork(Number(element('preset').value));
    engine.reset(nodes.length, edges);
    engine.configure(forceSettings());
    positions = engine.positions();
    selected = -1;
    updateSelection();
    element('node-count').textContent = nodes.length.toLocaleString();
    element('edge-count').textContent = edges.length.toLocaleString();
    running = true;
    automaticFit = true;
    fitGraph();
    requestFrame();
}

function updateStatus() {
    element('pause').textContent = paused ? 'Resume' : 'Pause';
    element('pause').setAttribute('aria-pressed', String(paused));
    element('status').textContent = paused ? 'Paused · drag still available' : running ? 'Simulation running' : 'Settled · drag to wake';
    element('status-dot').classList.toggle('active', !paused && running);
}

function requestFrame() {
    if (!frame && engine) frame = requestAnimationFrame(renderFrame);
    updateStatus();
}

function wakeEngine() {
    engine.reheat();
    running = true;
    requestFrame();
}

function renderFrame() {
    frame = 0;
    try {
        if (!paused && running) running = Boolean(engine.step());
        // Wasm memory can move during a step. Never retain an older view.
        positions = engine.positions();
        if (automaticFit) updateFittedCamera();
        drawGraph();
        updateStatus();
        if (!paused && running) requestFrame();
    } catch (error) {
        showFailure(error);
    }
}

function worldPoint(point) {
    return { x: (point.x - camera.x) / camera.scale, y: (point.y - camera.y) / camera.scale };
}

function pointerPoint(event) {
    const bounds = canvas.getBoundingClientRect();
    return { x: event.clientX - bounds.left, y: event.clientY - bounds.top };
}

function nodeRadius(index) {
    return index % Math.ceil(nodes.length / 3) === 0 ? 7 : 3.8;
}

function hitNode(point) {
    const world = worldPoint(point);
    for (let index = nodes.length - 1; index >= 0; index -= 1) {
        const radius = (nodeRadius(index) + 9) / camera.scale;
        if (Math.hypot(positions[index * 2] - world.x, positions[index * 2 + 1] - world.y) <= radius) return index;
    }
    return -1;
}

function drawGraph() {
    const ratio = window.devicePixelRatio || 1;
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, height);
    context.translate(camera.x, camera.y);
    context.scale(camera.scale, camera.scale);
    context.lineWidth = .8 / camera.scale;
    for (const [first, second] of edges) {
        const highlighted = selected === first || selected === second;
        context.strokeStyle = highlighted ? '#9baeea99' : '#637caa30';
        context.beginPath();
        context.moveTo(positions[first * 2], positions[first * 2 + 1]);
        context.lineTo(positions[second * 2], positions[second * 2 + 1]);
        context.stroke();
    }
    nodes.forEach((node, index) => drawNode(node, index));
    element('zoom').textContent = `${Math.round(camera.scale * 100)}%`;
}

function drawNode(node, index) {
    const x = positions[index * 2];
    const y = positions[index * 2 + 1];
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    const screenRadius = nodeRadius(index);
    const radius = screenRadius / camera.scale;
    context.fillStyle = colors[node.group];
    context.beginPath();
    context.arc(x, y, radius, 0, Math.PI * 2);
    context.fill();
    if (selected === index) {
        context.strokeStyle = '#ffffffbb';
        context.lineWidth = 1.5 / camera.scale;
        context.beginPath();
        context.arc(x, y, radius + 5 / camera.scale, 0, Math.PI * 2);
        context.stroke();
    }
    if (selected === index || (nodes.length <= 100 && screenRadius === 7)) {
        context.font = `${11 / camera.scale}px -apple-system, BlinkMacSystemFont, sans-serif`;
        context.fillStyle = '#ced8ed';
        context.textAlign = 'center';
        context.fillText(node.name, x, y + radius + 17 / camera.scale);
    }
}

// Fit node centers inside a measured, padded area, leaving room for labels.
function fittedCamera(points, area) {
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (let index = 0; index < points.length; index += 2) {
        const x = points[index];
        const y = points[index + 1];
        if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
        minX = Math.min(minX, x);
        maxX = Math.max(maxX, x);
        minY = Math.min(minY, y);
        maxY = Math.max(maxY, y);
    }
    if (!Number.isFinite(minX)) return null;
    const scale = Math.min(1.5, Math.max(1, area.width) / Math.max(100, maxX - minX), Math.max(1, area.height) / Math.max(100, maxY - minY));
    return {
        scale,
        x: area.x + area.width / 2 - (minX + maxX) / 2 * scale,
        y: area.y + area.height / 2 - (minY + maxY) / 2 * scale,
    };
}

function graphFitArea() {
    const canvasBounds = canvas.getBoundingClientRect();
    const headingBounds = document.querySelector('.graph-heading').getBoundingClientRect();
    const toolbarBounds = document.querySelector('.graph-toolbar').getBoundingClientRect();
    const top = headingBounds.bottom - canvasBounds.top + 26;
    const bottom = toolbarBounds.top - canvasBounds.top - 32;
    return { x: 42, y: top, width: Math.max(1, width - 84), height: Math.max(1, bottom - top) };
}

function updateFittedCamera() {
    const fitted = fittedCamera(positions, graphFitArea());
    if (fitted) camera = fitted;
}

function fitGraph() {
    updateFittedCamera();
    requestFrame();
}

function zoomAt(point, factor) {
    const anchor = worldPoint(point);
    camera.scale = Math.max(.08, Math.min(5, camera.scale * factor));
    camera.x = point.x - anchor.x * camera.scale;
    camera.y = point.y - anchor.y * camera.scale;
    requestFrame();
}

function updateSelection() {
    const node = nodes[selected];
    element('selected-name').textContent = node ? node.name : 'A space for discovery';
    element('selected-description').textContent = node ? `${categories[node.group]} · ${edges.filter(([a, b]) => a === selected || b === selected).length} connections. Drag to reshape the network.` : 'Select a node to see where it belongs.';
}

function finishGesture() {
    const capturedPointers = [...pointers.keys()];
    if (gesture?.type === 'node' && engine) engine.endDrag(gesture.index);
    gesture = null;
    pointers.clear();
    for (const pointerId of capturedPointers) {
        if (canvas.hasPointerCapture(pointerId)) canvas.releasePointerCapture(pointerId);
    }
}

function startPointer(event) {
    if (!engine || (event.pointerType === 'mouse' && event.button !== 0)) return;
    automaticFit = false;
    canvas.setPointerCapture(event.pointerId);
    const point = pointerPoint(event);
    pointers.set(event.pointerId, point);
    if (pointers.size > 1) {
        if (gesture?.type === 'node') engine.endDrag(gesture.index);
        const [first, second] = [...pointers.values()];
        gesture = { type: 'pinch', distance: Math.hypot(first.x - second.x, first.y - second.y), midpoint: { x: (first.x + second.x) / 2, y: (first.y + second.y) / 2 } };
        return;
    }
    const index = hitNode(point);
    if (index >= 0) {
        selected = index;
        updateSelection();
        const world = worldPoint(point);
        gesture = { type: 'node', index, offsetX: positions[index * 2] - world.x, offsetY: positions[index * 2 + 1] - world.y };
        engine.beginDrag(index, positions[index * 2], positions[index * 2 + 1]);
        wakeEngine();
    } else {
        gesture = { type: 'pan', point };
    }
}

function movePointer(event) {
    if (!pointers.has(event.pointerId)) return;
    const point = pointerPoint(event);
    pointers.set(event.pointerId, point);
    if (gesture?.type === 'pinch' && pointers.size >= 2) {
        const [first, second] = [...pointers.values()];
        const midpoint = { x: (first.x + second.x) / 2, y: (first.y + second.y) / 2 };
        const distance = Math.hypot(first.x - second.x, first.y - second.y);
        camera.x += midpoint.x - gesture.midpoint.x;
        camera.y += midpoint.y - gesture.midpoint.y;
        zoomAt(midpoint, distance / Math.max(1, gesture.distance));
        gesture = { type: 'pinch', distance, midpoint };
    } else if (gesture?.type === 'node') {
        const world = worldPoint(point);
        engine.drag(gesture.index, world.x + gesture.offsetX, world.y + gesture.offsetY);
        wakeEngine();
    } else if (gesture?.type === 'pan') {
        camera.x += point.x - gesture.point.x;
        camera.y += point.y - gesture.point.y;
        gesture.point = point;
        requestFrame();
    }
}

function endPointer(event) {
    if (!pointers.has(event.pointerId)) return;
    if (gesture?.type === 'node') {
        engine.endDrag(gesture.index);
        wakeEngine();
    }
    pointers.delete(event.pointerId);
    const remaining = [...pointers.values()][0];
    gesture = remaining ? { type: 'pan', point: remaining } : null;
}

function resizeCanvas() {
    const bounds = canvas.getBoundingClientRect();
    const previousWidth = width;
    const previousHeight = height;
    width = bounds.width;
    height = bounds.height;
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    camera.x += (width - previousWidth) / 2;
    camera.y += (height - previousHeight) / 2;
    if (engine && automaticFit) updateFittedCamera();
    requestFrame();
}

function showFailure(error) {
    cancelAnimationFrame(frame);
    frame = 0;
    finishGesture();
    engine = null;
    element('notice').hidden = false;
    element('notice-text').textContent = 'The Swift WebAssembly engine could not start or continue. Please retry. If this persists, the demo assets may still be deploying.';
    element('retry').hidden = false;
    element('settings').disabled = true;
    for (const id of ['pause', 'fit', 'reset']) element(id).disabled = true;
    element('engine-badge').textContent = 'Swift · Wasm unavailable';
    element('engine-badge').classList.remove('ready');
    element('status').textContent = 'Engine unavailable';
    element('status-dot').classList.remove('active');
    console.error('ForceGraph Wasm engine failed:', error);
}

async function loadEngine() {
    if (loading) return;
    loading = true;
    element('retry').hidden = true;
    element('notice-text').textContent = 'Loading the Swift engine (about 20 MB). The first visit may take a moment…';
    try {
        const { WasmForceGraph } = await import('./engine.js');
        engine = await WasmForceGraph.load(new URL('./forcegraph.wasm.gz', import.meta.url));
        resetNetwork();
        element('notice').hidden = true;
        element('settings').disabled = false;
        for (const id of ['pause', 'fit', 'reset']) element(id).disabled = false;
        element('engine-badge').textContent = 'Swift · WebAssembly';
        element('engine-badge').classList.add('ready');
    } catch (error) {
        showFailure(error);
    } finally {
        loading = false;
    }
}

element('preset').addEventListener('change', resetNetwork);
element('reset').addEventListener('click', resetNetwork);
element('fit').addEventListener('click', () => { automaticFit = false; fitGraph(); });
element('retry').addEventListener('click', loadEngine);
element('pause').addEventListener('click', () => { paused = !paused; requestFrame(); });
element('reheat').addEventListener('click', () => { paused = false; wakeEngine(); });
for (const id of ['repulsion', 'distance', 'center']) {
    element(id).addEventListener('input', () => {
        element(`${id}-value`).value = element(id).value;
        engine.configure(forceSettings());
        wakeEngine();
    });
}
canvas.addEventListener('pointerdown', startPointer);
canvas.addEventListener('pointermove', movePointer);
canvas.addEventListener('pointerup', endPointer);
canvas.addEventListener('pointercancel', endPointer);
canvas.addEventListener('lostpointercapture', endPointer);
canvas.addEventListener('wheel', (event) => {
    if (!engine) return;
    event.preventDefault();
    automaticFit = false;
    const delta = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? height : 1);
    zoomAt(pointerPoint(event), Math.exp(-Math.max(-300, Math.min(300, delta)) * .002));
}, { passive: false });
canvas.addEventListener('keydown', (event) => {
    if (!engine) return;
    automaticFit = false;
    if (event.key === '+' || event.key === '=') zoomAt({ x: width / 2, y: height / 2 }, 1.2);
    else if (event.key === '-') zoomAt({ x: width / 2, y: height / 2 }, 1 / 1.2);
    else if (event.key === '0') fitGraph();
    else if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
        selected = (selected + (event.key === 'ArrowRight' ? 1 : -1) + nodes.length) % nodes.length;
        updateSelection();
        requestFrame();
    } else return;
    event.preventDefault();
});
window.addEventListener('blur', () => {
    const hadGesture = gesture !== null;
    finishGesture();
    if (engine && hadGesture) wakeEngine();
});
new ResizeObserver(resizeCanvas).observe(canvas);
resizeCanvas();
loadEngine();
