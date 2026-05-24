package com.example.springaichatdemo.chat;

public class ChatServiceException extends RuntimeException {

    public ChatServiceException(String message, Throwable cause) {
        super(message, cause);
    }
}
