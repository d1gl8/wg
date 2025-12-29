import {
  addPeerToConfig,
  listToConfig,
  generateNewPeer,
} from './wg-add-client.ts';
(async () => {
  const result = await addPeerToConfig(
    await generateNewPeer('mc_keks' + Date.now()),
    './wg0.conf'
  );
  console.debug(result);
  // await listToConfig();
})();

process.stdout.on('data', data => console.debug('d', data));
process.on('SIGTERM', data => console.debug('d', data));
// console.debug(process);
