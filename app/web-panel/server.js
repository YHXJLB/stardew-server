const PS_HOME = process.env.PS_HOME || require('path').join(require('os').homedir(), 'puppy-stardew', 'home', 'steam');
/**
 * Puppy Stardew Server - Web Management Panel
 * Main server entry point
 */

const express = require('express');
const http = require('http');
const path = require('path');
const { WebSocketServer } = require('ws');
const auth = require('./auth');

// ─── Configuration ───────────────────────────────────────────────
const PORT = parseInt(process.env.PANEL_PORT || process.env.SERVER_PORT || '24642', 10);

// Paths (inside container)
const DATA_DIR = process.env.PANEL_DATA_DIR || path.join(__dirname, 'data');
const STATUS_FILE = process.env.STATUS_FILE || PS_HOME + '/.local/share/puppy-stardew/status.json';
const LOG_DIR = process.env.LOG_DIR || PS_HOME + '/.local/share/puppy-stardew/logs';
const SAVES_DIR = process.env.SAVES_DIR || PS_HOME + '/.config/StardewValley/Saves';
const BACKUPS_DIR = process.env.BACKUPS_DIR || PS_HOME + '/.local/share/puppy-stardew/backups';
const GAME_DIR = process.env.GAME_DIR || PS_HOME + '/stardewvalley';
const SMAPI_LOG = process.env.SMAPI_LOG || PS_HOME + '/.config/StardewValley/ErrorLogs/SMAPI-latest.txt';
const ENV_FILE = process.env.ENV_FILE || PS_HOME + '/web-panel/data/runtime.env';

// Export paths for use by API modules
const config = {
  PORT,
  DATA_DIR,
  STATUS_FILE,
  LOG_DIR,
  SAVES_DIR,
  BACKUPS_DIR,
  GAME_DIR,
  SMAPI_LOG,
  ENV_FILE,
};
module.exports = config;

// ─── Express App ─────────────────────────────────────────────────
const app = express();
const server = http.createServer(app);

// Middleware
app.use(express.json({ limit: '60mb' }));
app.use(express.urlencoded({ extended: false, limit: '60mb' }));

// ─── Auth Routes (no JWT required) ───────────────────────────────
app.get('/api/auth/status', auth.getStatus);
app.post('/api/auth/setup', auth.setup);
app.post('/api/auth/login', auth.login);
app.get('/api/auth/verify', auth.verifyMiddleware, auth.verify);
app.post('/api/auth/password', auth.verifyMiddleware, auth.changePassword);

// ─── API Routes (JWT required) ──────────────────────────────────
// Status API
const statusAPI = require('./api/status');
app.get('/api/status', auth.verifyMiddleware, statusAPI.getStatus);

// Logs API
const logsAPI = require('./api/logs');
app.get('/api/logs', auth.verifyMiddleware, logsAPI.getLogs);

// Players API
const playersAPI = require('./api/players');
app.get('/api/players', auth.verifyMiddleware, playersAPI.getPlayers);

// Saves API
const savesAPI = require('./api/saves');
app.get('/api/saves', auth.verifyMiddleware, savesAPI.getSaves);
app.get('/api/saves/backups', auth.verifyMiddleware, savesAPI.getBackups);
app.get('/api/saves/backup/status', auth.verifyMiddleware, savesAPI.getBackupStatus);
app.post('/api/saves/backup', auth.verifyMiddleware, savesAPI.createBackup);
app.post('/api/saves/upload', auth.verifyMiddleware, savesAPI.uploadSave);
app.post('/api/saves/default', auth.verifyMiddleware, savesAPI.setDefaultSave);
app.get('/api/saves/download/:filename', auth.verifyMiddleware, savesAPI.downloadBackup);

// Config API
const configAPI = require('./api/config');
app.get('/api/config', auth.verifyMiddleware, configAPI.getConfig);
app.put('/api/config', auth.verifyMiddleware, configAPI.updateConfig);

// Server control API
app.post('/api/server/restart', auth.verifyMiddleware, statusAPI.restartServer);
app.post('/api/container/restart', auth.verifyMiddleware, statusAPI.restartContainer);

// Mods API
const modsAPI = require('./api/mods');
app.get('/api/mods', auth.verifyMiddleware, modsAPI.getMods);
app.post('/api/mods/upload', auth.verifyMiddleware, modsAPI.uploadMod);
app.delete('/api/mods/:folder', auth.verifyMiddleware, modsAPI.deleteMod);

// ─── Static Files ────────────────────────────────────────────────
app.use(express.static(path.join(__dirname, 'public')));

// SPA fallback - serve index.html for all non-API routes
app.get('*', (req, res) => {
  if (req.path.startsWith('/api/')) {
    return res.status(404).json({ error: 'Not found' });
  }
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// ─── WebSocket Server ────────────────────────────────────────────
const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (ws, req) => {
  // Parse token from query string
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const token = url.searchParams.get('token');

  if (!token || !auth.verifyToken(token)) {
    ws.close(4001, 'Unauthorized');
    return;
  }

  console.log('[WebSocket] Client connected');

  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data.toString());
      handleWebSocketMessage(ws, msg);
    } catch (e) {
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid message format' }));
    }
  });

  ws.on('close', () => {
    console.log('[WebSocket] Client disconnected');
    // Clean up any log subscriptions or terminal sessions
    if (ws._logWatcher) {
      ws._logWatcher.close();
      ws._logWatcher = null;
    }
    if (ws._terminalProc) {
      ws._terminalProc.kill();
      ws._terminalProc = null;
    }
  });
});

function handleWebSocketMessage(ws, msg) {
  switch (msg.type) {
    case 'subscribe':
      if (msg.channel === 'logs') {
        logsAPI.subscribeLogs(ws, msg.filter || 'all');
      } else if (msg.channel === 'status') {
        statusAPI.subscribeStatus(ws);
      }
      break;

    case 'unsubscribe':
      if (msg.channel === 'logs' && ws._logWatcher) {
        ws._logWatcher.close();
        ws._logWatcher = null;
      }
      break;

    case 'terminal:input':
      const terminalAPI = require('./api/terminal');
      terminalAPI.handleInput(ws, msg.data);
      break;

    case 'terminal:open':
      const terminalAPI2 = require('./api/terminal');
      terminalAPI2.openTerminal(ws);
      break;

    case 'terminal:close':
      if (ws._terminalProc) {
        ws._terminalProc.kill();
        ws._terminalProc = null;
      }
      break;

    default:
      ws.send(JSON.stringify({ type: 'error', message: `Unknown message type: ${msg.type}` }));
  }
}

// ─── Initialize & Start ──────────────────────────────────────────
async function start() {
  // Initialize auth and detect whether first-run setup is required.
  await auth.initialize(DATA_DIR);

  server.listen(PORT, '0.0.0.0', () => {
    console.log(`[Web Panel] ✅ Management panel running on http://0.0.0.0:${PORT}`);
  });
}

start().catch((err) => {
  console.error('[Web Panel] Failed to start:', err);
  process.exit(1);
});
