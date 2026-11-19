package taskorg.project;

import org.springframework.data.repository.ListCrudRepository;

import java.util.List;

public interface ProjectRepository extends ListCrudRepository<Project, Long> {
    List<Project> findAllByOrderByIdAsc();
}
