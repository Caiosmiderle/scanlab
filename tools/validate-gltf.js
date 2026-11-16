// Valida arquivos glTF/GLB com o validador oficial da Khronos (pacote npm gltf-validator).
// Uso: node tools/validate-gltf.js arquivo1.glb arquivo2.gltf ...
// Sai com código 1 se algum arquivo tiver erro.
const fs = require('fs');
const path = require('path');
const validator = require('gltf-validator');

async function validate(file) {
  const bytes = new Uint8Array(fs.readFileSync(file));
  const report = await validator.validateBytes(bytes, {
    uri: path.basename(file),
    // Para o .gltf, que referencia um .bin ao lado.
    externalResourceFunction: (uri) =>
      new Promise((resolve, reject) => {
        fs.readFile(path.join(path.dirname(file), uri), (error, data) => {
          if (error) {
            reject(error.toString());
          } else {
            resolve(new Uint8Array(data));
          }
        });
      }),
  });
  const issues = report.issues;
  console.log(`${file}: erros=${issues.numErrors} avisos=${issues.numWarnings} infos=${issues.numInfos} dicas=${issues.numHints}`);
  for (const message of issues.messages) {
    console.log(`  [severidade ${message.severity}] ${message.code}: ${message.message} ${message.pointer || ''}`);
  }
  return issues.numErrors === 0;
}

(async () => {
  let allValid = true;
  for (const file of process.argv.slice(2)) {
    const valid = await validate(file);
    allValid = allValid && valid;
  }
  process.exit(allValid ? 0 : 1);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
