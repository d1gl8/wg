import { execFile, execFileSync, spawn } from 'child_process';
import { access, copyFile, mkdir, readFile, writeFile } from 'fs/promises';
import path from 'path';

const WG_CONF_DIR = '/etc/wireguard';
const WG_CONF_FILE = `${WG_CONF_DIR}/wg0.conf`;
const WG_PRIVATE_KEY_FILE = `${WG_CONF_DIR}/private.key`;
const WG_PEERS_FILE = `${WG_CONF_DIR ?? '.'}/peers.list.json}`;

const getNextIp = (ipWithMask: string): string | null => {
  const [ip, mask] = ipWithMask.split('/');
  const parts = ip.split('.');
  if (parts.length !== 4) return null;
  const nums = parts.map(p => Number(p));
  if (nums.some(n => !Number.isInteger(n) || n < 0 || n > 255)) return null;

  // Пропускаем сетевой(0) и broadcast(255) как недопустимые хосты
  if (nums[3] <= 0 || nums[3] >= 255) return null;

  // Инкрементируем последний октет
  nums[3]++;
  if (nums[3] === 255) {
    // переходим к следующему октету слева
    nums[3] = 1;
    for (let i = 2; i >= 0; i--) {
      nums[i]++;
      if (nums[i] <= 255) break;
      // перенёсся выше 255 -> сброс в 0 и продолжаем перенос
      nums[i] = 0;
      if (i === 0 && nums[0] === 0) return null; // переполнение всего адресного пространства
    }
  }
  return nums.join('.') + `/${mask}`;
};

export const keyGenerate = async (privateKeyFile?: string) => {
  const privateKey = await readCheckFile(
    WG_PRIVATE_KEY_FILE,
    './private.key'
  ).catch(() => {
    throw new Error('файл приватного ключа не получен');
  });
  try {
    const out = execFileSync('wg', ['genkey'], {
      input: String(privateKey),
      encoding: 'utf-8',
    });
    return out.trim();
  } catch {
    throw new Error('$ wg genkey');
  }
};

const readCheckFile = async (filePath: string, secondPath: string) => {
  await access(filePath).catch(err => {
    filePath = secondPath;
  });
  return await readFile(filePath);
};

const checkDuplicates = async peerObject => {
  const config = await readFile('./wg0.conf', 'utf8');
  const [[peerName, peer]] = Object.entries(peerObject);

  let duplicate = null;
  const lines = config.split(/\r?\n/);
  for (const lineRaw of lines) {
    const line = lineRaw.trim();
    if (!line) continue;
    if (
      line.toLowerCase().startsWith('allowedips') ||
      line.toLowerCase().startsWith('publickey')
    ) {
      const trimLine = (line: string | null) => {
        if (!line) return '';
        return line
          .split(',')
          .map(x => x.trim())
          .filter(Boolean)
          .join(',');
      };
      const newIp = trimLine(peer.AllowedIPs); // единый формат: без пробелов после запятых
      const newKey = peer.PublicKey.trim();
      const parts = line.split('=');
      if (parts.length >= 2) {
        const value = parts.slice(1).join('=').trim();
        const lineValue = trimLine(value);
        duplicate = [newIp, newKey].find(val => lineValue.includes(val));
        if (duplicate) break;
      }
      continue;
    }
  }

  if (duplicate) {
    return { duplicate };
  }

  return { config, duplicate };
};

export const generateNewPeer = async (name, filePath?: string) => {
  const peers = await readCheckFile(WG_PEERS_FILE, './peers.list.json').then(
    string => JSON.parse(String(string))
  );
  if (peers[name]) throw new Error('Peer с таким именем уже существует');
  const lastIdx = Object.keys(peers).length - 1;
  const { AllowedIPs: lastIp } = Object.values(peers)[lastIdx];

  const now = new Date();
  const peer = {
    [name]: {
      PublicKey: await keyGenerate(),
      AllowedIPs: getNextIp(lastIp),
      created: now.toLocaleString('ru'),
    },
  };

  const args = [
    'set',
    'wg0',
    'peer',
    peer[name].PublicKey,
    'allowed-ips',
    peer[name].AllowedIPs,
  ];
  const p = spawn('wg', args, { stdio: 'inherit' });

  p.on('close', code => process.exit(code));
  p.on('error', err => {
    console.error('Failed to start:', err.message);
    process.exit(1);
  });

  console.debug('generateNewPeer ' + name);
  return peer;
};

type NewPeer = {
  PeerName: {
    PublicKey: string;
    AllowedIPs: string;
    Endpoint?: string;
    PersistentKeepalive?: number;
  };
};

function generatePeerSection(peerObject: NewPeer): string {
  const [[name, peer]] = Object.entries(peerObject);
  // console.debug(name, peer);

  if (!peer.PublicKey || !peer.AllowedIPs) {
    throw new Error('PublicKey и AllowedIPs обязательны');
  }
  const pub = peer.PublicKey.trim();
  const ips = peer.AllowedIPs.trim();
  const endpoint = peer.Endpoint?.trim();
  const keepalive = peer.PersistentKeepalive;

  const lines: string[] = [`# ${name}`, '[Peer]'];
  lines.push(`PublicKey = ${pub}`);
  if (endpoint) lines.push(`Endpoint = ${endpoint}`);
  lines.push(`AllowedIPs = ${ips}`);
  if (typeof keepalive === 'number')
    lines.push(`PersistentKeepalive = ${keepalive}`);

  return lines.join('\n') + '\n';
}

async function fileExists(p: string): Promise<boolean> {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

export async function addPeerToConfig(peerObject, confPath = WG_CONF_FILE) {
  // Создаём резервную копию
  // const ts = new Date().toISOString().replace(/[:.]/g, '-');
  // const backupPath = `${confPath}.bak.${ts}`;
  // await copyFile(confPath, backupPath);
  // console.debug(peerObj);

  const [[peerName, peer]] = Object.entries(peerObject);

  const { duplicate, config } = await checkDuplicates(peerObject);
  if (duplicate) {
    const reason = duplicate === peer.PublicKey ? 'PublicKey' : 'AllowedIPs';
    return {
      added: false,
      message: `Peer ${peerName} не добавлен в конфигурацию. ${reason} ${duplicate} уже существует.`,
    };
  }
  if (!config) return;

  const sec = generatePeerSection(peerObject);

  // Дописываем секцию в конец, с пустой строкой перед секцией
  const newContent = config.replace(/\s*$/, '') + '\n\n' + sec;
  await writeFile(confPath, newContent, { mode: 0o600 });
  const peers = await readCheckFile(WG_PEERS_FILE, './peers.list.json').then(
    string => JSON.parse(String(string))
  );
  await writeFile(
    './peers.list.json',
    JSON.stringify({ ...peers, ...peerObject })
  );

  return {
    added: true,
    message: `Peer ${peerName} добавлен в конфигурацию.`,
    // backupPath,
  };
}

export const listToConfig = async () => {
  const peers = await readCheckFile(WG_PEERS_FILE, './peers.list.json').then(
    string => JSON.parse(String(string))
  );

  for await (const [name, peer] of Object.entries(peers)) {
    const result = await addPeerToConfig({ [name]: peer }, './wg0.conf');
    console.debug(result);
  }
};
