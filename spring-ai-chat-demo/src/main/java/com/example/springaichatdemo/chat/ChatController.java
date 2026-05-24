package com.example.springaichatdemo.chat;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/chat")
public class ChatController {

    private final ChatService chatService;

    public ChatController(ChatService chatService) {
        this.chatService = chatService;
    }

    @PostMapping
    public ResponseEntity<?> chat(@RequestBody ChatRequest request) {
        if (request == null || request.prompt() == null || request.prompt().isBlank()) {
            return ResponseEntity.badRequest().body(ApiError.of("El campo prompt es obligatorio."));
        }

        return ResponseEntity.ok(this.chatService.chat(request.prompt().trim()));
    }

    @ExceptionHandler(ChatServiceException.class)
    public ResponseEntity<ApiError> handleChatServiceException(ChatServiceException ex) {
        return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(ApiError.of(ex.getMessage()));
    }
}
