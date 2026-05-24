package com.example.springaichatdemo.chat;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(ChatController.class)
class ChatControllerTests {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private ChatService chatService;

    @Test
    void rejectsBlankPrompt() throws Exception {
        this.mockMvc.perform(post("/api/chat")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"prompt\":\"   \"}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.message").value("El campo prompt es obligatorio."));

        verifyNoInteractions(this.chatService);
    }

    @Test
    void returnsChatResponse() throws Exception {
        given(this.chatService.chat(anyString()))
                .willReturn(new ChatResponse("ollama", "llama3.2:1b", "Hola"));

        this.mockMvc.perform(post("/api/chat")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"prompt\":\"Hola\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.provider").value("ollama"))
                .andExpect(jsonPath("$.model").value("llama3.2:1b"))
                .andExpect(jsonPath("$.response").value("Hola"));
    }

    @Test
    void mapsChatErrorsToBadGateway() throws Exception {
        given(this.chatService.chat(anyString()))
                .willThrow(new ChatServiceException("Ollama no responde", new RuntimeException("boom")));

        this.mockMvc.perform(post("/api/chat")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"prompt\":\"Hola\"}"))
                .andExpect(status().isBadGateway())
                .andExpect(jsonPath("$.message").value("Ollama no responde"));
    }
}
