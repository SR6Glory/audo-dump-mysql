import { Knex } from "knex";
const knex = require("knex");

export type KnexList = {
  source: Knex;
  destination: Knex;
};

function createKnexList(
  knexConfigs: { config?: string; name: string; server: string }[]
): KnexList {
  const knexPools = {};

  for (let i = 0; i < knexConfigs.length; i++) {
    const { config, name, server } = knexConfigs[i];
    knexPools[name] = knex({
      client: server,
      connection: config,
      pool: {
        min: 2,
        max: 10,
      },
      dateStrings: true,
    });
  }

  //runInitialState(knexPools['default']);
  return knexPools as unknown as KnexList;
}

export function createKnexConnectionsFromSetting() {
  return createKnexList([
    { name: "source", config: process.env.MYSQL_SOURCE, server: "mysql2" },
    {
      name: "destination",
      config: process.env.MYSQL_DESTINATION,
      server: "mysql2",
    },
  ]);
}
