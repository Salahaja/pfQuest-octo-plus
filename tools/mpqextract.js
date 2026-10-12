// Extracts files from the client's archives whose names match a pattern,
// keeping each archive's copy apart (out/<archive>/<path>), so the newest
// patch can be picked afterwards.
//
//   set ELECTRON_RUN_AS_NODE=1 && electron mpqextract.js <client Data dir> <regex> <out dir>
//
// Read a client that is not running: WoW holds its archives open (error 32).
// stormlib-node is built against Electron's ABI, so this runs under Electron.
const path = require('path');
const fs = require('fs');
const storm = require('D:/stuff/OctoLauncher-src/octolauncher/node_modules/stormlib-node');

const [data, pattern, outdir] = process.argv.slice(2);
const re = new RegExp(pattern, 'i');
const SEP = String.fromCharCode(92);

function readFile(h, name) {
	const fh = storm.SFileOpenFileEx(h, name, 0);
	const size = Number(storm.SFileGetFileSize(fh));
	const buf = new ArrayBuffer(size);
	storm.SFileReadFile(fh, buf);
	storm.SFileCloseFile(fh);
	return Buffer.from(buf);
}

for (const f of fs.readdirSync(data).filter(f => /^patch.*\.mpq$/i.test(f))) {
	const h = storm.SFileOpenArchive(path.join(data, f), 0x100 /* READ_ONLY */);
	try {
		if (!storm.SFileHasFile(h, '(listfile)')) continue;
		const names = readFile(h, '(listfile)').toString('latin1').split(/\r?\n/).filter(n => re.test(n));
		for (const n of names) {
			const out = path.join(outdir, f, n.split(SEP).join('/'));
			fs.mkdirSync(path.dirname(out), { recursive: true });
			fs.writeFileSync(out, readFile(h, n));
		}
		console.log(f, names.length);
	} finally {
		storm.SFileCloseArchive(h);
	}
}
