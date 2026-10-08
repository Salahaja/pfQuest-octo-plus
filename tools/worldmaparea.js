// Reads DBFilesClient\WorldMapArea.dbc out of the client's archives (the
// newest patch that carries it wins, as in game) and prints its rows as JSON:
// every map's extents in world coordinates.
//
//   set ELECTRON_RUN_AS_NODE=1 && electron worldmaparea.js <client Data dir>
// (stormlib-node is built against Electron's ABI, so it runs under Electron.)
const path = require('path');
const fs = require('fs');
const storm = require('D:/stuff/OctoLauncher-src/octolauncher/node_modules/stormlib-node');

const data = process.argv[2];
// lettered patches over numbered over patch.mpq over dbc.mpq, last first
const files = fs.readdirSync(data);
const rank = f => {
	const m = f.toLowerCase().match(/^patch-([a-z0-9])\.mpq$/);
	if (m) return /[a-z]/.test(m[1]) ? 1000 + m[1].charCodeAt(0) : 500 + Number(m[1]);
	if (f.toLowerCase() === 'patch.mpq') return 100;
	if (f.toLowerCase() === 'dbc.mpq') return 1;
	return -1;
};
const order = files.filter(f => rank(f) > 0).sort((a, b) => rank(b) - rank(a));

function read(name) {
	for (const f of order) {
		const h = storm.SFileOpenArchive(path.join(data, f), 0x100 /* READ_ONLY */);
		try {
			if (!storm.SFileHasFile(h, name)) continue;
			const fh = storm.SFileOpenFileEx(h, name, 0);
			const size = Number(storm.SFileGetFileSize(fh));
			const buf = new ArrayBuffer(size);
			storm.SFileReadFile(fh, buf);
			storm.SFileCloseFile(fh);
			return { from: f, buf: Buffer.from(buf) };
		} finally {
			storm.SFileCloseArchive(h);
		}
	}
	throw new Error('not found: ' + name);
}

const { from, buf } = read('DBFilesClient\\WorldMapArea.dbc');
if (buf.toString('ascii', 0, 4) !== 'WDBC') throw new Error('not a DBC');
const records = buf.readUInt32LE(4), fields = buf.readUInt32LE(8), size = buf.readUInt32LE(12);
const strings = 20 + records * size;
const str = off => buf.toString('utf8', strings + off, buf.indexOf(0, strings + off));
const rows = [];
for (let r = 0; r < records; r++) {
	const o = 20 + r * size;
	rows.push({
		id: buf.readInt32LE(o), map: buf.readInt32LE(o + 4), area: buf.readInt32LE(o + 8),
		name: str(buf.readUInt32LE(o + 12)),
		left: buf.readFloatLE(o + 16), right: buf.readFloatLE(o + 20),
		top: buf.readFloatLE(o + 24), bottom: buf.readFloatLE(o + 28),
	});
}
console.log(JSON.stringify({ from, records, fields, size, rows }));
