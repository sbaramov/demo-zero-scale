let projects = [];
let selectedProjectId = null;

const errorBanner = document.getElementById("error-banner");
const projectForm = document.getElementById("project-form");
const projectNameInput = document.getElementById("project-name");
const projectDescInput = document.getElementById("project-description");
const projectListEl = document.getElementById("project-list");

const selectedProjectNameEl = document.getElementById("selected-project-name");
const selectedProjectDescEl = document.getElementById("selected-project-description");
const deleteProjectBtn = document.getElementById("delete-project-btn");
const taskForm = document.getElementById("task-form");
const taskTitleInput = document.getElementById("task-title");
const taskListEl = document.getElementById("task-list");
const emptyTasksMsg = document.getElementById("empty-tasks-msg");

function showError(message) {
    errorBanner.textContent = message;
    errorBanner.classList.remove("d-none");
}

function clearError() {
    errorBanner.textContent = "";
    errorBanner.classList.add("d-none");
}

async function apiFetch(url, options = {}) {
    clearError();
    const response = await fetch(url, {
        headers: { "Content-Type": "application/json", ...(options.headers || {}) },
        ...options
    });
    if (!response.ok) {
        let message = `Request failed (${response.status})`;
        try {
            const body = await response.json();
            if (body && body.error) {
                message = body.error;
            }
        } catch (_) {
            // ignore non-JSON error bodies
        }
        throw new Error(message);
    }
    return response.status === 204 ? null : response.json();
}

function renderProjects() {
    projectListEl.replaceChildren();
    if (projects.length === 0) {
        const empty = document.createElement("div");
        empty.className = "text-muted small";
        empty.textContent = "No projects yet.";
        projectListEl.appendChild(empty);
        return;
    }
    for (const project of projects) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "list-group-item list-group-item-action" +
            (project.id === selectedProjectId ? " active" : "");
        btn.textContent = project.name;
        btn.addEventListener("click", () => selectProject(project.id));
        projectListEl.appendChild(btn);
    }
}

function renderTasks(tasks) {
    taskListEl.replaceChildren();
    emptyTasksMsg.classList.toggle("d-none", tasks.length > 0);
    for (const task of tasks) {
        const li = document.createElement("li");
        li.className = "list-group-item d-flex justify-content-between align-items-center px-0";

        const label = document.createElement("label");
        label.className = "d-flex align-items-center gap-2 mb-0 flex-grow-1";

        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.className = "form-check-input mt-0";
        checkbox.checked = Boolean(task.completed);
        checkbox.addEventListener("change", async () => {
            try {
                await apiFetch(`/api/tasks/${task.id}`, {
                    method: "PATCH",
                    body: JSON.stringify({ completed: checkbox.checked })
                });
                await loadTasks(selectedProjectId);
            } catch (err) {
                showError(err.message);
            }
        });

        const span = document.createElement("span");
        span.textContent = task.title;
        if (task.completed) {
            span.className = "text-decoration-line-through text-muted";
        }

        const delBtn = document.createElement("button");
        delBtn.type = "button";
        delBtn.className = "btn btn-outline-secondary btn-sm";
        delBtn.textContent = "Delete";
        delBtn.addEventListener("click", async () => {
            try {
                await apiFetch(`/api/tasks/${task.id}`, { method: "DELETE" });
                await loadTasks(selectedProjectId);
            } catch (err) {
                showError(err.message);
            }
        });

        label.appendChild(checkbox);
        label.appendChild(span);
        li.appendChild(label);
        li.appendChild(delBtn);
        taskListEl.appendChild(li);
    }
}

async function loadTasks(projectId) {
    const tasks = await apiFetch(`/api/projects/${projectId}/tasks`);
    renderTasks(tasks);
}

async function selectProject(projectId) {
    selectedProjectId = projectId;
    const project = projects.find(p => p.id === projectId);
    renderProjects();
    if (!project) {
        selectedProjectNameEl.textContent = "Select a project";
        selectedProjectDescEl.textContent = "";
        deleteProjectBtn.classList.add("d-none");
        taskForm.classList.add("d-none");
        taskListEl.replaceChildren();
        emptyTasksMsg.classList.add("d-none");
        return;
    }
    selectedProjectNameEl.textContent = project.name;
    selectedProjectDescEl.textContent = project.description || "";
    deleteProjectBtn.classList.remove("d-none");
    taskForm.classList.remove("d-none");
    await loadTasks(project.id);
}

async function loadProjects() {
    try {
        projects = await apiFetch("/api/projects");
        if (projects.length > 0 && !projects.some(p => p.id === selectedProjectId)) {
            await selectProject(projects[0].id);
        } else if (projects.length === 0) {
            await selectProject(null);
        } else {
            await selectProject(selectedProjectId);
        }
    } catch (err) {
        showError(err.message);
    }
}

projectForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
        const created = await apiFetch("/api/projects", {
            method: "POST",
            body: JSON.stringify({
                name: projectNameInput.value,
                description: projectDescInput.value
            })
        });
        projectNameInput.value = "";
        projectDescInput.value = "";
        selectedProjectId = created.id;
        await loadProjects();
    } catch (err) {
        showError(err.message);
    }
});

deleteProjectBtn.addEventListener("click", async () => {
    if (!selectedProjectId) return;
    try {
        await apiFetch(`/api/projects/${selectedProjectId}`, { method: "DELETE" });
        selectedProjectId = null;
        await loadProjects();
    } catch (err) {
        showError(err.message);
    }
});

taskForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!selectedProjectId) return;
    try {
        await apiFetch(`/api/projects/${selectedProjectId}/tasks`, {
            method: "POST",
            body: JSON.stringify({ title: taskTitleInput.value })
        });
        taskTitleInput.value = "";
        await loadTasks(selectedProjectId);
    } catch (err) {
        showError(err.message);
    }
});

loadProjects();
