-- =============================================================================
-- Demo-Datenbank für Backup-Demonstration
-- =============================================================================

-- Tabelle: Benutzer
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Tabelle: Projekte
CREATE TABLE IF NOT EXISTS projects (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    owner_id INTEGER REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Tabelle: Aufgaben
CREATE TABLE IF NOT EXISTS tasks (
    id SERIAL PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    completed BOOLEAN DEFAULT FALSE,
    project_id INTEGER REFERENCES projects(id),
    assigned_to INTEGER REFERENCES users(id),
    due_date DATE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Demo-Daten einfügen
INSERT INTO users (email, name) VALUES
    ('admin@example.com', 'Admin User'),
    ('developer@example.com', 'Dev User'),
    ('manager@example.com', 'Project Manager')
ON CONFLICT (email) DO NOTHING;

INSERT INTO projects (name, description, owner_id) VALUES
    ('Backup Demo', 'Demonstration von PostgreSQL Container Backups', 1),
    ('API Development', 'REST API für die Anwendung', 2),
    ('Documentation', 'Projekt-Dokumentation', 3)
ON CONFLICT DO NOTHING;

INSERT INTO tasks (title, completed, project_id, assigned_to, due_date) VALUES
    ('Docker Compose erstellen', TRUE, 1, 2, CURRENT_DATE - INTERVAL '7 days'),
    ('Backup Schedule konfigurieren', TRUE, 1, 2, CURRENT_DATE - INTERVAL '5 days'),
    ('S3 Integration testen', FALSE, 1, 2, CURRENT_DATE + INTERVAL '3 days'),
    ('Dokumentation schreiben', FALSE, 1, 1, CURRENT_DATE + INTERVAL '7 days'),
    ('API Endpoints definieren', FALSE, 2, 2, CURRENT_DATE + INTERVAL '14 days')
ON CONFLICT DO NOTHING;

-- Ausgabe zur Bestätigung
DO $$
BEGIN
    RAISE NOTICE '=== Demo-Daten erfolgreich geladen ===';
    RAISE NOTICE 'Users: %', (SELECT COUNT(*) FROM users);
    RAISE NOTICE 'Projects: %', (SELECT COUNT(*) FROM projects);
    RAISE NOTICE 'Tasks: %', (SELECT COUNT(*) FROM tasks);
END $$;
