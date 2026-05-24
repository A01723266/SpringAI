package com.example.springaichatdemo.chat;

import org.springframework.ai.chat.client.ChatClient;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

@Service
public class ChatService {

    private final ChatClient chatClient;
    private final String model;

    public ChatService(ChatClient.Builder chatClientBuilder,
            @Value("${spring.ai.ollama.chat.options.model:llama3.2:1b}") String model) {
        this.chatClient = chatClientBuilder.build();
        this.model = model;
    }

    public ChatResponse chat(String prompt) {
        try {
            String content = this.chatClient.prompt()
                    .user(prompt)
                    .call()
                    .content();

            return new ChatResponse("ollama", this.model, content);
        }
        catch (Exception ex) {
            throw new ChatServiceException("No se pudo obtener respuesta de Ollama. Verifica que Docker/Ollama este activo y que el modelo este descargado.", ex);
        }
    }
}
