import { Knex } from "knex";
import { createKnexConnectionsFromSetting } from "./createKnexConnectionList";
import cliProgress from "cli-progress";

async function getTables(knex: Knex): Promise<string[]> {
  const [rows] = await knex.raw("SHOW TABLES;");
  return rows.map((r: Record<string, string>) => Object.values(r)[0]);
}

function addIfNotExistsToCreate(createStmt: string): string {
  return createStmt.replace(
    /^CREATE\s+TABLE\s+/i,
    "CREATE TABLE IF NOT EXISTS "
  );
}

async function getCreateTable(knex: Knex, table: string): Promise<string> {
  const [rows] = await knex.raw(`SHOW CREATE TABLE \`${table}\`;`);
  return rows[0]["Create Table"] as string;
}

async function ensureTableOnDest(knexDest: Knex, createStmt: string) {
  const stmt = addIfNotExistsToCreate(createStmt);
  await knexDest.raw(stmt);
}

async function getPrimaryKeyColumns(
  knex: Knex,
  table: string
): Promise<string[]> {
  const [rows] = await knex.raw(`SHOW INDEX FROM \`${table}\`;`);
  return rows
    .filter((r: any) => r.Key_name === "PRIMARY")
    .sort((a: any, b: any) => a.Seq_in_index - b.Seq_in_index)
    .map((r: any) => r.Column_name);
}

async function getFirstUniqueIndexColumns(
  knex: Knex,
  table: string
): Promise<string[]> {
  const [rows] = await knex.raw(`SHOW INDEX FROM \`${table}\`;`);
  const byIndex: Record<string, { seq: number; col: string }[]> = {};
  for (const r of rows) {
    if (r.Non_unique === 0 && r.Key_name !== "PRIMARY") {
      if (!byIndex[r.Key_name]) byIndex[r.Key_name] = [];
      byIndex[r.Key_name].push({ seq: r.Seq_in_index, col: r.Column_name });
    }
  }
  const first = Object.keys(byIndex)[0];
  if (!first) return [];
  return byIndex[first].sort((a, b) => a.seq - b.seq).map((x) => x.col);
}

async function getColumns(knex: Knex, table: string): Promise<string[]> {
  const info = await knex(table).columnInfo();
  return Object.keys(info);
}

async function getRowCount(knex: Knex, table: string): Promise<number> {
  const [rows] = await knex.raw(`SELECT COUNT(*) AS c FROM \`${table}\``);
  return rows[0].c as number;
}

async function fetchBatch(
  knex: Knex,
  table: string,
  cols: string[],
  offset: number,
  limit: number
) {
  const orderCol = cols[0];
  return knex(table)
    .select(cols)
    .orderBy(orderCol, "asc")
    .offset(offset)
    .limit(limit);
}

function chunkArray<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

async function upsertBatch(
  knexDest: Knex,
  table: string,
  rows: any[],
  conflictCols: string[]
) {
  if (rows.length === 0) return;

  const INSERT_CHUNK = 2000;
  const chunks = chunkArray(rows, INSERT_CHUNK);

  for (const chunk of chunks) {
    if (conflictCols.length > 0) {
      await knexDest(table).insert(chunk).onConflict(conflictCols).merge();
    } else {
      await knexDest(table).insert(chunk);
    }
  }
}

async function run() {
  const knexPools = createKnexConnectionsFromSetting();
  const knexSource = knexPools.source;
  const knexDest = knexPools.destination;

  if (!knexSource) throw new Error("Source connection not found.");
  if (!knexDest) throw new Error("Destination connection not found.");

  // Parse exclude list from env
  const excludeTables = (process.env.EXCLUDE_TABLE || "")
    .replace(/[\[\]]/g, "") // remove square brackets if present
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean);

  let tables = await getTables(knexSource);
  if (excludeTables.length > 0) {
    tables = tables.filter((t) => !excludeTables.includes(t));
    console.log(`Excluding tables: ${excludeTables.join(", ")}`);
  }

  const BATCH_SIZE = 5000;

  for (const tableName of tables) {
    const createStmt = await getCreateTable(knexSource, tableName);
    await ensureTableOnDest(knexDest, createStmt);

    const pkCols = await getPrimaryKeyColumns(knexSource, tableName);
    const uniqueCols = pkCols.length
      ? pkCols
      : await getFirstUniqueIndexColumns(knexSource, tableName);
    const allCols = await getColumns(knexSource, tableName);

    const total = await getRowCount(knexSource, tableName);
    console.log(
      `\n[${tableName}] total rows: ${total} (conflict key: ${
        uniqueCols.join(",") || "none"
      })`
    );

    const bar = new cliProgress.SingleBar(
      {
        format: `[${tableName}] [{bar}] {percentage}% | {value}/{total} rows`,
        hideCursor: true,
      },
      cliProgress.Presets.shades_classic
    );

    bar.start(total, 0);

    for (let offset = 0; offset < total; offset += BATCH_SIZE) {
      const batch = await fetchBatch(
        knexSource,
        tableName,
        allCols,
        offset,
        BATCH_SIZE
      );
      await upsertBatch(knexDest, tableName, batch, uniqueCols);
      bar.update(Math.min(offset + BATCH_SIZE, total));
    }

    bar.stop();
  }

  await knexSource.destroy();
  await knexDest.destroy();
}

run().catch((e) => {
  console.error("Error:", e);
  process.exit(1);
});
