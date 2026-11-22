package taskorg.task;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;
import taskorg.project.ProjectRepository;

import java.time.Instant;
import java.util.List;

@RestController
public class TaskController {

    /** Matches {@code tasks.title VARCHAR(300)} in schema.sql. */
    static final int MAX_TITLE_LENGTH = 300;

    private final TaskRepository taskRepository;
    private final ProjectRepository projectRepository;

    public TaskController(TaskRepository taskRepository, ProjectRepository projectRepository) {
        this.taskRepository = taskRepository;
        this.projectRepository = projectRepository;
    }

    public record CreateTaskRequest(String title) {
    }

    public record UpdateTaskRequest(String title, Boolean completed) {
    }

    @GetMapping("/api/projects/{projectId}/tasks")
    public List<Task> listTasks(@PathVariable Long projectId) {
        if (!projectRepository.existsById(projectId)) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Project not found: " + projectId);
        }
        return taskRepository.findByProjectIdOrderByIdAsc(projectId);
    }

    // Validation is done by hand instead of via spring-boot-starter-validation (Bean Validation)
    // to keep the classpath, and therefore cold-start time, as small as possible.
    @PostMapping("/api/projects/{projectId}/tasks")
    @ResponseStatus(HttpStatus.CREATED)
    public Task createTask(@PathVariable Long projectId, @RequestBody CreateTaskRequest request) {
        if (!projectRepository.existsById(projectId)) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Project not found: " + projectId);
        }
        String title = validateTitle(request == null ? null : request.title());
        return taskRepository.save(new Task(null, projectId, title, false, Instant.now()));
    }

    @PatchMapping("/api/tasks/{id}")
    public Task updateTask(@PathVariable Long id, @RequestBody UpdateTaskRequest request) {
        Task existing = taskRepository.findById(id)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "Task not found: " + id));
        String title = existing.title();
        if (request != null && request.title() != null) {
            title = validateTitle(request.title());
        }
        boolean completed = (request != null && request.completed() != null)
                ? request.completed()
                : existing.completed();
        return taskRepository.save(new Task(existing.id(), existing.projectId(), title, completed, existing.createdAt()));
    }

    private static String validateTitle(String rawTitle) {
        if (rawTitle == null || rawTitle.isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Task title must not be blank");
        }
        String trimmed = rawTitle.trim();
        if (trimmed.length() > MAX_TITLE_LENGTH) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "Task title must be at most " + MAX_TITLE_LENGTH + " characters");
        }
        return trimmed;
    }

    @DeleteMapping("/api/tasks/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void deleteTask(@PathVariable Long id) {
        if (!taskRepository.existsById(id)) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Task not found: " + id);
        }
        taskRepository.deleteById(id);
    }
}
