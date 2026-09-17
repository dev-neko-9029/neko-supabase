// Genera un lote de etiquetas en stock con códigos de tres palabras
// (estándar de alta, sección 2.9).
// Uso: node generate-tags.mjs <cantidad> <nombre-del-lote>
// Escribe tags/<nombre-del-lote>.json y evita los códigos que ya existen en
// los otros lotes. La restricción de unicidad de food.tags es la garantía
// final.
import { randomInt } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const MAX_BATCH = 500;
const here = dirname(fileURLToPath(import.meta.url));
const tagsDir = join(here, 'tags');

const count = Number.parseInt(process.argv[2] ?? '', 10);
const batchName = process.argv[3] ?? '';
if (!Number.isInteger(count) || count < 1 || count > MAX_BATCH || !/^[a-z0-9-]+$/.test(batchName)) {
  console.error(`Uso: node generate-tags.mjs <cantidad entre 1 y ${MAX_BATCH}> <nombre-del-lote>`);
  process.exit(1);
}

const outFile = join(tagsDir, `${batchName}.json`);
if (existsSync(outFile)) {
  console.error(`Ya existe ${outFile}. Un lote no se sobrescribe.`);
  process.exit(1);
}

const words = readFileSync(join(here, 'words.txt'), 'utf8')
  .split('\n')
  .map((line) => line.trim())
  .filter((line) => line.length > 0);

const existing = new Set();
for (const file of readdirSync(tagsDir)) {
  if (!file.endsWith('.json')) continue;
  const batch = JSON.parse(readFileSync(join(tagsDir, file), 'utf8'));
  for (const tag of batch) existing.add(tag.code);
}

const pick = () => words[randomInt(words.length)];
const batch = [];
while (batch.length < count) {
  const parts = [pick(), pick(), pick()];
  // Palabras repetidas dentro de un código lo hacen más difícil de leer.
  if (new Set(parts).size < 3) continue;
  const code = parts.join('-');
  if (existing.has(code)) continue;
  existing.add(code);
  batch.push({ code });
}

writeFileSync(outFile, `${JSON.stringify(batch, null, 2)}\n`);
console.log(`${count} etiquetas escritas en ${outFile}`);
