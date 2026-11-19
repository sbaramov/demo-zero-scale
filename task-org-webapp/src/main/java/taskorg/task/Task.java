package taskorg.task;

import org.springframework.data.annotation.Id;
import org.springframework.data.relational.core.mapping.Table;

import java.time.Instant;

@Table("tasks")
public record Task(
        @Id Long id,
        Long projectId,
        String title,
        boolean completed,
        Instant createdAt
) {
}
