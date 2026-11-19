package taskorg.project;

import org.springframework.data.annotation.Id;
import org.springframework.data.relational.core.mapping.Table;

import java.time.Instant;

@Table("projects")
public record Project(
        @Id Long id,
        String name,
        String description,
        Instant createdAt
) {
}
