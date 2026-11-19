package taskorg;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.data.jdbc.test.autoconfigure.DataJdbcTest;
import org.springframework.boot.jdbc.test.autoconfigure.AutoConfigureTestDatabase;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
import org.springframework.test.context.ActiveProfiles;
import taskorg.project.Project;
import taskorg.project.ProjectRepository;
import taskorg.task.Task;
import taskorg.task.TaskRepository;

import javax.sql.DataSource;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

@DataJdbcTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@ActiveProfiles("test")
class PersistenceTests {

    @Autowired
    ProjectRepository projectRepository;

    @Autowired
    TaskRepository taskRepository;

    @Autowired
    DataSource dataSource;

    @Test
    void savesAndListsProjectsAndTasksAndCascadesDelete() {
        Project saved = projectRepository.save(new Project(null, "Alpha", "First project", Instant.now()));
        assertThat(saved.id()).isNotNull();

        taskRepository.save(new Task(null, saved.id(), "Task 1", false, Instant.now()));
        taskRepository.save(new Task(null, saved.id(), "Task 2", true, Instant.now()));
        assertThat(taskRepository.findByProjectIdOrderByIdAsc(saved.id()))
                .extracting(Task::title)
                .containsExactly("Task 1", "Task 2");

        projectRepository.deleteById(saved.id());
        assertThat(taskRepository.findByProjectIdOrderByIdAsc(saved.id())).isEmpty();
    }

    @Test
    void seedDataDoesNotResurrectDeletedProjectsOnColdStartReinit() {
        projectRepository.deleteAll();
        projectRepository.save(new Project(null, "Custom Project", "User created", Instant.now()));

        // Simulate a subsequent pod cold start re-running data.sql
        new ResourceDatabasePopulator(new ClassPathResource("data.sql")).execute(dataSource);

        assertThat(projectRepository.findAllByOrderByIdAsc())
                .extracting(Project::name)
                .containsExactly("Custom Project");
    }
}
