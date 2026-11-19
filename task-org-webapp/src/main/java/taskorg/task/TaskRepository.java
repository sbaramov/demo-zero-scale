package taskorg.task;

import org.springframework.data.repository.ListCrudRepository;

import java.util.List;

public interface TaskRepository extends ListCrudRepository<Task, Long> {
    List<Task> findByProjectIdOrderByIdAsc(Long projectId);
}
