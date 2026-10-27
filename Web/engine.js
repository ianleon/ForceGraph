const ERRNO = Object.freeze({ SUCCESS: 0, BADF: 8, FAULT: 21, INVAL: 28, NOSYS: 52, SPIPE: 70, NOTCAPABLE: 76 });

export class WasiExit extends Error {
    constructor(code) {
        super(`WASI process exited with status ${code}`);
        this.code = code;
    }
}

/** Minimal browser Preview1 host. Memory is supplied after instantiation. */
export class WasiPreview1 {
    constructor({ performance = globalThis.performance, crypto = globalThis.crypto, write = () => {} } = {}) {
        this.memory = null;
        this.performance = performance;
        this.crypto = crypto;
        this.write = write;
        this.imports = {
            clock_time_get: (clock, precision, output) => this.clockTime(clock, output),
            clock_res_get: (clock, output) => this.clockResolution(clock, output),
            fd_write: (fd, vectors, count, output) => this.writeVectors(fd, vectors, count, output),
            fd_read: (fd, vectors, count, output) => this.readVectors(fd, vectors, count, output),
            fd_fdstat_get: (fd, output) => this.fdStat(fd, output),
            args_sizes_get: (count, size) => this.emptySizes(count, size),
            args_get: () => ERRNO.SUCCESS,
            environ_sizes_get: (count, size) => this.emptySizes(count, size),
            environ_get: () => ERRNO.SUCCESS,
            random_get: (pointer, length) => this.random(pointer, length),
            proc_exit: code => { throw new WasiExit(code); },
            fd_close: fd => fd >= 0 && fd <= 2 ? ERRNO.SUCCESS : ERRNO.BADF,
            fd_seek: fd => fd >= 0 && fd <= 2 ? ERRNO.SPIPE : ERRNO.BADF,
            fd_prestat_get: () => ERRNO.BADF,
            fd_prestat_dir_name: () => ERRNO.BADF,
            sched_yield: () => ERRNO.SUCCESS,
        };
        // This host grants no filesystem capabilities or preopened directories.
        for (const name of ['fd_fdstat_set_flags', 'fd_filestat_get', 'fd_filestat_set_size', 'fd_filestat_set_times', 'fd_pread', 'fd_readdir', 'fd_sync', 'fd_tell']) {
            this.imports[name] = () => ERRNO.BADF;
        }
        for (const name of ['path_create_directory', 'path_filestat_get', 'path_filestat_set_times', 'path_link', 'path_open', 'path_readlink', 'path_remove_directory', 'path_rename', 'path_symlink', 'path_unlink_file']) {
            this.imports[name] = () => ERRNO.NOTCAPABLE;
        }
        this.imports.poll_oneoff = () => ERRNO.NOSYS;
    }

    region(pointer, length) {
        const buffer = this.memory?.buffer;
        if (!buffer || !Number.isInteger(pointer) || !Number.isInteger(length) || pointer < 0 || length < 0 || pointer > buffer.byteLength - length) return null;
        return new Uint8Array(buffer, pointer, length);
    }

    view(pointer, length) {
        const bytes = this.region(pointer, length);
        return bytes ? new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength) : null;
    }

    emptySizes(count, size) {
        const countView = this.view(count, 4);
        const sizeView = this.view(size, 4);
        if (!countView || !sizeView) return ERRNO.FAULT;
        countView.setUint32(0, 0, true);
        sizeView.setUint32(0, 0, true);
        return ERRNO.SUCCESS;
    }

    clockTime(clock, output) {
        if (clock !== 0 && clock !== 1) return ERRNO.INVAL;
        const view = this.view(output, 8);
        if (!view) return ERRNO.FAULT;
        const milliseconds = clock === 0 ? Date.now() : this.performance.now();
        view.setBigUint64(0, BigInt(Math.floor(milliseconds * 1e6)), true);
        return ERRNO.SUCCESS;
    }

    clockResolution(clock, output) {
        if (clock !== 0 && clock !== 1) return ERRNO.INVAL;
        const view = this.view(output, 8);
        if (!view) return ERRNO.FAULT;
        view.setBigUint64(0, 1000000n, true);
        return ERRNO.SUCCESS;
    }

    vectors(pointer, count) {
        const table = this.view(pointer, count * 8);
        if (!table) return null;
        const regions = [];
        for (let index = 0; index < count; index++) {
            const region = this.region(table.getUint32(index * 8, true), table.getUint32(index * 8 + 4, true));
            if (!region) return null;
            regions.push(region);
        }
        return regions;
    }

    writeVectors(fd, pointer, count, output) {
        if (fd !== 1 && fd !== 2) return ERRNO.BADF;
        const result = this.view(output, 4);
        const regions = this.vectors(pointer, count);
        if (!result || !regions) return ERRNO.FAULT;
        let total = 0;
        for (const region of regions) {
            this.write(fd, region.slice());
            total += region.length;
        }
        result.setUint32(0, total, true);
        return ERRNO.SUCCESS;
    }

    readVectors(fd, pointer, count, output) {
        if (fd !== 0) return ERRNO.BADF;
        const result = this.view(output, 4);
        if (!result || !this.vectors(pointer, count)) return ERRNO.FAULT;
        // No interactive stdin: a read observes end of file.
        result.setUint32(0, 0, true);
        return ERRNO.SUCCESS;
    }

    fdStat(fd, output) {
        if (fd < 0 || fd > 2) return ERRNO.BADF;
        const bytes = this.region(output, 24);
        if (!bytes) return ERRNO.FAULT;
        bytes.fill(0);
        bytes[0] = 2; // Character device.
        const view = this.view(output, 24);
        view.setBigUint64(8, fd === 0 ? 2n : 64n, true); // FD_READ / FD_WRITE.
        return ERRNO.SUCCESS;
    }

    random(pointer, length) {
        const bytes = this.region(pointer, length);
        if (!bytes) return ERRNO.FAULT;
        if (!this.crypto?.getRandomValues) throw new Error('WASI random_get requires crypto.getRandomValues');
        for (let offset = 0; offset < length; offset += 65536) this.crypto.getRandomValues(bytes.subarray(offset, offset + 65536));
        return ERRNO.SUCCESS;
    }

    /** Reject unknown imports before instantiating, with the precise ABI name. */
    importsFor(module) {
        for (const entry of WebAssembly.Module.imports(module)) {
            if (entry.module !== 'wasi_snapshot_preview1' || entry.kind !== 'function' || !Object.hasOwn(this.imports, entry.name)) {
                throw new Error(`Unsupported Wasm import: ${entry.module}.${entry.name} (${entry.kind})`);
            }
        }
        return { wasi_snapshot_preview1: this.imports };
    }
}

const ENGINE_EXPORTS = ['fg_reset', 'fg_add_edge', 'fg_start', 'fg_configure', 'fg_step', 'fg_x', 'fg_y', 'fg_begin_drag', 'fg_drag', 'fg_end_drag', 'fg_reheat'];

function finite(value, label) {
    if (typeof value !== 'number' || !Number.isFinite(value)) throw new TypeError(`${label} must be a finite number`);
    return value;
}

async function moduleBytes(response) {
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) return bytes;
    if (typeof globalThis.DecompressionStream !== 'function') {
        throw new Error('Loading gzip-compressed ForceGraph Wasm requires browser DecompressionStream support');
    }
    const decompressed = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
    return new Response(decompressed).arrayBuffer();
}

export class WasmForceGraph {
    static async load(url) {
        const response = await fetch(url);
        if (!response.ok) throw new Error(`Unable to fetch ForceGraph Wasm: HTTP ${response.status}`);
        const module = await WebAssembly.compile(await moduleBytes(response));
        const wasi = new WasiPreview1();
        const instance = await WebAssembly.instantiate(module, wasi.importsFor(module));
        const engine = new WasmForceGraph(instance.exports);
        if (!(instance.exports.memory instanceof WebAssembly.Memory)) throw new Error('ForceGraph Wasm must export memory');
        wasi.memory = instance.exports.memory;
        const initialize = instance.exports._initialize ?? instance.exports._start;
        if (initialize !== undefined) {
            if (typeof initialize !== 'function') throw new Error('Invalid Wasm initialization export');
            try { initialize(); } catch (error) {
                if (!(error instanceof WasiExit) || error.code !== 0) throw error;
            }
        }
        return engine;
    }

    constructor(exports) {
        for (const name of ENGINE_EXPORTS) {
            if (typeof exports[name] !== 'function') throw new Error(`Missing ForceGraph Wasm function: ${name}`);
        }
        this.exports = exports;
        this.nodeCount = 0;
        this.positionBuffer = new Float64Array(0);
    }

    index(index) {
        if (!Number.isInteger(index) || index < 0 || index >= this.nodeCount) throw new RangeError('Node index is outside the graph');
        return index;
    }

    reset(nodeCount, edgesPairs) {
        if (!Number.isInteger(nodeCount) || nodeCount < 0 || nodeCount > 1000) throw new RangeError('Node count must be an integer between 0 and 1000');
        if (!Array.isArray(edgesPairs)) throw new TypeError('Edges must be an array of [source, target] pairs');
        if (edgesPairs.length > 10000) throw new RangeError('Edge count must not exceed 10000');
        for (const pair of edgesPairs) {
            if (!Array.isArray(pair) || pair.length !== 2 || pair.some(index => !Number.isInteger(index) || index < 0 || index >= nodeCount)) throw new RangeError('Invalid edge pair');
        }
        const buffer = new Float64Array(nodeCount * 2);
        this.exports.fg_reset(nodeCount);
        for (const [source, target] of edgesPairs) this.exports.fg_add_edge(source, target);
        this.exports.fg_start();
        this.nodeCount = nodeCount;
        this.positionBuffer = buffer;
    }

    configure({ repulsion, linkDistance, centerStrength }) {
        this.exports.fg_configure(finite(repulsion, 'repulsion'), finite(linkDistance, 'linkDistance'), finite(centerStrength, 'centerStrength'));
    }

    step() { return Boolean(this.exports.fg_step()); }

    positions() {
        for (let index = 0; index < this.nodeCount; index++) {
            this.positionBuffer[index * 2] = this.exports.fg_x(index);
            this.positionBuffer[index * 2 + 1] = this.exports.fg_y(index);
        }
        return this.positionBuffer;
    }

    beginDrag(index, x, y) { this.exports.fg_begin_drag(this.index(index), finite(x, 'x'), finite(y, 'y')); }
    drag(index, x, y) { this.exports.fg_drag(this.index(index), finite(x, 'x'), finite(y, 'y')); }
    endDrag(index) { this.exports.fg_end_drag(this.index(index)); }
    reheat() { this.exports.fg_reheat(); }
}
