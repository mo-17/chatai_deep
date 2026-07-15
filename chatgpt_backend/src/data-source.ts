import 'reflect-metadata';
import { DataSource } from 'typeorm';
import * as dotenv from 'dotenv';
import { buildPostgresOptions } from './database/postgres-options';
dotenv.config();

export default new DataSource({
  ...buildPostgresOptions((key) => process.env[key], __dirname),
  migrations: [__dirname + '/migrations/*.{ts,js}'],
});
