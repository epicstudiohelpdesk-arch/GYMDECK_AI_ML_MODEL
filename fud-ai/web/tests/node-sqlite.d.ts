declare module "node:sqlite" {
  export class DatabaseSync {
    constructor(path: string);
    exec(sql: string): void;
    prepare(sql: string): {
      run(...values: Array<string | number | null>): { changes: number | bigint; lastInsertRowid: number | bigint };
      get(...values: Array<string | number | null>): Record<string, string | number | null> | undefined;
      all(...values: Array<string | number>): Array<Record<string, string | number>>;
    };
    close(): void;
  }
}
