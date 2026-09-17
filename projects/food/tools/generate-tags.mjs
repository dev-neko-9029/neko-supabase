// Genera un lote de estantes en stock con códigos de tres palabras
// (estándar de alta, sección 2.9) y su seed.
// Uso: node tools/generate-tags.mjs <cantidad> <número-de-lote>
// Escribe seeds/2NN_tags_lote_NNN.json y .sql. Evita los códigos que ya
// aparecen en cualquier JSON de seeds/. La restricción de unicidad de
// food.tags es la garantía final.
import { randomInt } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const MAX_BATCH = 500;
// Los lotes ocupan el rango 200-299 de los seeds de food.
const MAX_BATCH_NUMBER = 99;
const here = dirname(fileURLToPath(import.meta.url));
const seedsDir = join(here, '..', 'seeds');

const count = Number.parseInt(process.argv[2] ?? '', 10);
const batchNumber = Number.parseInt(process.argv[3] ?? '', 10);
if (
  !Number.isInteger(count) || count < 1 || count > MAX_BATCH ||
  !Number.isInteger(batchNumber) || batchNumber < 1 || batchNumber > MAX_BATCH_NUMBER
) {
  console.error(`Uso: node tools/generate-tags.mjs <cantidad 1-${MAX_BATCH}> <número de lote 1-${MAX_BATCH_NUMBER}>`);
  process.exit(1);
}

const lote = String(batchNumber).padStart(3, '0');
const base = `${200 + batchNumber}_tags_lote_${lote}`;
const jsonFile = join(seedsDir, `${base}.json`);
const sqlFile = join(seedsDir, `${base}.sql`);
if (existsSync(jsonFile) || existsSync(sqlFile)) {
  console.error(`Ya existe ${base}. Un lote no se sobrescribe.`);
  process.exit(1);
}

const words = readFileSync(join(here, 'words.txt'), 'utf8')
  .split('\n')
  .map((line) => line.trim())
  .filter((line) => line.length > 0);

const existing = new Set();
for (const file of readdirSync(seedsDir)) {
  if (!file.endsWith('.json')) continue;
  const content = JSON.parse(readFileSync(join(seedsDir, file), 'utf8'));
  if (!Array.isArray(content)) continue;
  for (const entry of content) {
    if (typeof entry?.code === 'string') existing.add(entry.code);
  }
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

writeFileSync(jsonFile, `${JSON.stringify(batch, null, 2)}\n`);
writeFileSync(
  sqlFile,
  `-- Lote ${lote} de estantes, en stock. Un lote no se edita después de imprimirlo.\nselect food.import_tags(:'data'::jsonb);\n`,
);
console.log(`${count} estantes en seeds/${base}.json. Se cargan en el próximo deploy.`);
