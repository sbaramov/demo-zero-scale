INSERT INTO projects (name, description)
SELECT 'Zero-Scale Article', 'Demo tasks for the Istio + KEDA + Project Leyden article'
WHERE NOT EXISTS (SELECT 1 FROM projects);

INSERT INTO projects (name, description)
SELECT 'Personal Errands', 'Everyday tasks organized by project'
WHERE (SELECT COUNT(*) FROM projects) = 1;

INSERT INTO tasks (project_id, title, completed)
SELECT p.id, 'Set up k3d cluster with Istio and KEDA', true
FROM projects p
WHERE p.name = 'Zero-Scale Article'
  AND NOT EXISTS (SELECT 1 FROM tasks WHERE project_id = p.id);

INSERT INTO tasks (project_id, title, completed)
SELECT p.id, 'Benchmark Project Leyden AOT cold start', false
FROM projects p
WHERE p.name = 'Zero-Scale Article'
  AND (SELECT COUNT(*) FROM tasks WHERE project_id = p.id) = 1;

INSERT INTO tasks (project_id, title, completed)
SELECT p.id, 'Pick up coffee beans', false
FROM projects p
WHERE p.name = 'Personal Errands'
  AND NOT EXISTS (SELECT 1 FROM tasks WHERE project_id = p.id);
