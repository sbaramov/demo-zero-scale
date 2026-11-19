package taskorg;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import tools.jackson.databind.ObjectMapper;

import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.not;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class ApiAndUiTests {

    @Autowired
    MockMvc mockMvc;

    @Autowired
    ObjectMapper objectMapper;

    @Test
    void projectAndTaskCrudLifecycle() throws Exception {
        MvcResult createProject = mockMvc.perform(post("/api/projects")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"Demo Project","description":"Zero-scale test"}
                                """))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").isNumber())
                .andExpect(jsonPath("$.name").value("Demo Project"))
                .andReturn();

        long projectId = objectMapper.readTree(createProject.getResponse().getContentAsString()).get("id").asLong();

        mockMvc.perform(get("/api/projects"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.id == " + projectId + ")].name").value("Demo Project"));

        MvcResult createTask = mockMvc.perform(post("/api/projects/" + projectId + "/tasks")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"title":"Write Leyden Dockerfile"}
                                """))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.completed").value(false))
                .andReturn();

        long taskId = objectMapper.readTree(createTask.getResponse().getContentAsString()).get("id").asLong();

        mockMvc.perform(get("/api/projects/" + projectId + "/tasks"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].title").value("Write Leyden Dockerfile"));

        mockMvc.perform(patch("/api/tasks/" + taskId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"completed":true}
                                """))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.completed").value(true));

        mockMvc.perform(delete("/api/tasks/" + taskId))
                .andExpect(status().isNoContent());

        mockMvc.perform(delete("/api/projects/" + projectId))
                .andExpect(status().isNoContent());
    }

    @Test
    void rejectsBlankProjectNameAndTaskTitle() throws Exception {
        mockMvc.perform(post("/api/projects")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"   "}
                                """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").isNotEmpty());

        MvcResult created = mockMvc.perform(post("/api/projects")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"Valid Project"}
                                """))
                .andExpect(status().isCreated())
                .andReturn();
        long projectId = objectMapper.readTree(created.getResponse().getContentAsString()).get("id").asLong();

        mockMvc.perform(post("/api/projects/" + projectId + "/tasks")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"title":""}
                                """))
                .andExpect(status().isBadRequest());

        MvcResult taskCreated = mockMvc.perform(post("/api/projects/" + projectId + "/tasks")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"title":"Valid Task"}
                                """))
                .andExpect(status().isCreated())
                .andReturn();
        long taskId = objectMapper.readTree(taskCreated.getResponse().getContentAsString()).get("id").asLong();

        mockMvc.perform(patch("/api/tasks/" + taskId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"title":"  "}
                                """))
                .andExpect(status().isBadRequest());

        mockMvc.perform(delete("/api/projects/" + projectId))
                .andExpect(status().isNoContent());
    }

    @Test
    void returns404ForMissingProjectOrTask() throws Exception {
        mockMvc.perform(get("/api/projects/99999/tasks"))
                .andExpect(status().isNotFound());
        mockMvc.perform(post("/api/projects/99999/tasks")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"title":"Orphan task"}
                                """))
                .andExpect(status().isNotFound());
        mockMvc.perform(delete("/api/projects/99999"))
                .andExpect(status().isNotFound());
        mockMvc.perform(patch("/api/tasks/99999")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"completed":true}
                                """))
                .andExpect(status().isNotFound());
        mockMvc.perform(delete("/api/tasks/99999"))
                .andExpect(status().isNotFound());
    }

    @Test
    void servesBootstrapUiAndScript() throws Exception {
        mockMvc.perform(get("/index.html"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith(MediaType.TEXT_HTML))
                .andExpect(content().string(containsString("bootstrap")))
                .andExpect(content().string(containsString("app.js")));

        mockMvc.perform(get("/app.js"))
                .andExpect(status().isOk())
                .andExpect(content().string(containsString("/api/projects")))
                .andExpect(content().string(not(containsString(".innerHTML ="))));
    }

    @Test
    void exposesReadinessAndLivenessProbes() throws Exception {
        mockMvc.perform(get("/actuator/health/readiness"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));

        mockMvc.perform(get("/actuator/health/liveness"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }
}
