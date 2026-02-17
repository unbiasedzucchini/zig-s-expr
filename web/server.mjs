import { createServer } from 'http';
import { readFile } from 'fs/promises';
import { execFile } from 'child_process';
import { writeFile, unlink } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import { randomBytes } from 'crypto';

const PORT = 8000;
const ZSEXP = join(import.meta.dirname, '..', 'zig-out', 'bin', 'zsexp');

const server = createServer(async (req, res) => {
  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
    const html = await readFile(join(import.meta.dirname, 'index.html'));
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html);
    return;
  }

  if (req.method === 'POST' && req.url === '/api/compile') {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const source = Buffer.concat(chunks).toString();

    const id = randomBytes(8).toString('hex');
    const inPath = join(tmpdir(), `zsexp-${id}.sexpr`);
    const outPath = join(tmpdir(), `zsexp-${id}.wasm`);

    try {
      await writeFile(inPath, source);

      await new Promise((resolve, reject) => {
        execFile(ZSEXP, [inPath, outPath], { timeout: 5000 }, (err, stdout, stderr) => {
          if (err) reject(new Error(stderr || err.message));
          else resolve(stdout);
        });
      });

      const wasm = await readFile(outPath);
      res.writeHead(200, { 'Content-Type': 'application/wasm' });
      res.end(wasm);
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end(e.message);
    } finally {
      unlink(inPath).catch(() => {});
      unlink(outPath).catch(() => {});
    }
    return;
  }

  res.writeHead(404);
  res.end('not found');
});

server.listen(PORT, () => {
  console.log(`zsexp playground: http://localhost:${PORT}`);
});
