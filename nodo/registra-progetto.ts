// Registra un progetto nel Topics del nodo quando l'API lo rifiuta.
// Topics fino alla 2.3.30 accetta solo percorsi che iniziano con "/", quindi
// su Windows POST /api/projects risponde "path must be absolute" a ogni
// cartella vera (corretto nel ramo feat/pc-nodo di topics-app). Questo script
// scrive la stessa riga che scriverebbe l'API (project-store.ts create), con
// l'org dell'installazione come fa la rotta. Si usa solo come ripiego.
//
// L'id della riga e' l'id della BOARD (nome-hash del percorso), non un UUID.
// Fino alla 2.3.30 il nodo crea la card della corsa con l'id del progetto, e il
// dispatcher cerca la cartella solo per id della board: con un UUID la card si
// ferma con «non riesco a risalire alla directory del progetto». Con i due id
// uguali entrambe le strade trovano la stessa riga. Una riga gia' scritta con
// un UUID viene riallineata (progetto, card e worktree), una volta sola.
//
// Uso: bun registra-progetto.ts <topics.db> <nome> <slug> <percorso>
import { Database } from "bun:sqlite";

// Stessa funzione di shared/board.ts projectIdForPath in topics-app.
export function boardIdForPath(projectPath: string): string {
  const parts = projectPath.replace(/[\\/]+$/, "").split(/[\\/]/);
  const dirName = parts[parts.length - 1] || "project";
  let hash = 0;
  for (let i = 0; i < projectPath.length; i++) {
    hash = ((hash << 5) - hash) + projectPath.charCodeAt(i);
    hash |= 0;
  }
  return dirName + "-" + Math.abs(hash).toString(36).slice(0, 6);
}

if (import.meta.main) {
  const [dbPath, name, slug, path] = process.argv.slice(2);
  if (!dbPath || !name || !slug || !path) { console.error("uso: <db> <nome> <slug> <percorso>"); process.exit(2); }
  const db = new Database(dbPath);
  db.exec("PRAGMA busy_timeout = 5000");
  const id = boardIdForPath(path);
  const esiste = db.query("SELECT id FROM projects WHERE path = ?").get(path) as { id: string } | null;
  if (esiste && esiste.id === id) { console.log(id); process.exit(0); }
  if (esiste) {
    db.transaction(() => {
      db.query("UPDATE projects SET id = ? WHERE id = ?").run(id, esiste.id);
      db.query("UPDATE tasks SET project_id = ? WHERE project_id = ?").run(id, esiste.id);
      try { db.query("UPDATE worktrees SET project_id = ? WHERE project_id = ?").run(id, esiste.id); } catch { /* schema senza worktree */ }
    })();
    console.log(id);
    process.exit(0);
  }
  let org: string | null = null;
  try {
    const r = db.query(`SELECT i.org_id AS id FROM installation i JOIN orgs o ON o.id = i.org_id
                        WHERE i.singleton = 1 AND o.revoked_at IS NULL`).get() as { id: string } | null;
    org = r?.id ?? null;
  } catch { /* schema senza org: resta null, come per l'API */ }
  const now = new Date().toISOString();
  db.query(`INSERT INTO projects (id, name, slug, path, color, icon, archived, created_at, updated_at, org_id, owner_person_id)
            VALUES (?, ?, ?, ?, NULL, NULL, 0, ?, ?, ?, NULL)`).run(id, name, slug, path, now, now, org);
  console.log(id);
}
