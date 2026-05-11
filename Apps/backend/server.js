const http = require('http');
const { Client } = require('pg');

const client = new Client({
  host: process.env.PGHOST,
  database: process.env.PGDATABASE,
  user: process.env.PGUSER,
  password: process.env.PGPASSWORD,
});

async function init() {
  await client.connect();
  await client.query(`
    CREATE TABLE IF NOT EXISTS tasks (
      id SERIAL PRIMARY KEY,
      title TEXT NOT NULL,
      done BOOLEAN DEFAULT FALSE,
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);
  console.log('DB ready');
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => { data += chunk; });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Content-Type', 'application/json');

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const url = new URL(req.url, 'http://localhost');

  try {
    if (req.method === 'GET' && url.pathname === '/health') {
      res.writeHead(200);
      res.end(JSON.stringify({ status: 'ok', pod: process.env.POD_NAME }));
      return;
    }

    if (req.method === 'GET' && url.pathname === '/tasks') {
      const result = await client.query('SELECT * FROM tasks ORDER BY created_at DESC');
      res.writeHead(200);
      res.end(JSON.stringify(result.rows));
      return;
    }

    if (req.method === 'POST' && url.pathname === '/tasks') {
      const body = await readBody(req);
      let title;
      try {
        ({ title } = JSON.parse(body));
      } catch {
        res.writeHead(400);
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
        return;
      }
      if (!title || typeof title !== 'string') {
        res.writeHead(400);
        res.end(JSON.stringify({ error: 'title is required' }));
        return;
      }
      const result = await client.query(
        'INSERT INTO tasks (title) VALUES ($1) RETURNING *', [title]
      );
      res.writeHead(201);
      res.end(JSON.stringify(result.rows[0]));
      return;
    }

    if (req.method === 'PUT' && url.pathname.startsWith('/tasks/')) {
      const id = parseInt(url.pathname.split('/')[2], 10);
      if (isNaN(id)) { res.writeHead(400); res.end(JSON.stringify({ error: 'Invalid id' })); return; }
      const result = await client.query(
        'UPDATE tasks SET done = NOT done WHERE id = $1 RETURNING *', [id]
      );
      if (!result.rows.length) { res.writeHead(404); res.end(JSON.stringify({ error: 'Not found' })); return; }
      res.writeHead(200);
      res.end(JSON.stringify(result.rows[0]));
      return;
    }

    if (req.method === 'DELETE' && url.pathname.startsWith('/tasks/')) {
      const id = parseInt(url.pathname.split('/')[2], 10);
      if (isNaN(id)) { res.writeHead(400); res.end(JSON.stringify({ error: 'Invalid id' })); return; }
      await client.query('DELETE FROM tasks WHERE id = $1', [id]);
      res.writeHead(204);
      res.end();
      return;
    }

    res.writeHead(404);
    res.end(JSON.stringify({ error: 'Not found' }));
  } catch (err) {
    console.error(err);
    res.writeHead(500);
    res.end(JSON.stringify({ error: 'Internal server error' }));
  }
});

init().then(() => server.listen(3000, () => console.log('API listening on 3000')));
