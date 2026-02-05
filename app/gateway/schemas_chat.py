from typing import List, Optional, Union, Dict, Any
from pydantic import BaseModel, Field
import time

class ChatMessage(BaseModel):
    role: str
    content: str
    name: Optional[str] = None

class ChatCompletionRequest(BaseModel):
    model: Optional[str] = "glm-image"
    messages: List[ChatMessage]
    stream: Optional[bool] = False
    prefer_async: Optional[bool] = None
    max_tokens: Optional[int] = None # Ignored but allowed
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    n: Optional[int] = 1
    stop: Optional[Union[str, List[str]]] = None
    frequency_penalty: Optional[float] = None
    presence_penalty: Optional[float] = None
    logit_bias: Optional[Dict[str, float]] = None
    user: Optional[str] = None

class ChatChoice(BaseModel):
    index: int
    message: ChatMessage
    finish_reason: str = "stop"

class ChatUsage(BaseModel):
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0

class ChatCompletionResponse(BaseModel):
    id: str
    object: str = "chat.completion"
    created: int = Field(default_factory=lambda: int(time.time()))
    model: str
    choices: List[ChatChoice]
    usage: Optional[ChatUsage] = None
