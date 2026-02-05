from pydantic import BaseModel, Field
from typing import Optional, Literal, List, Union

class OpenAIImageGenerationRequest(BaseModel):
    prompt: str
    n: Optional[int] = Field(default=1)
    size: Optional[str] = Field(default=None)
    steps: Optional[int] = Field(default=None)
    response_format: Optional[Literal["b64_json", "url"]] = Field(default="b64_json")
    user: Optional[str] = Field(default=None)
    sync: Optional[bool] = Field(default=False)
    prefer_async: Optional[bool] = Field(default=False)

class OpenAIImageObject(BaseModel):
    b64_json: Optional[str] = None
    url: Optional[str] = None
    revised_prompt: Optional[str] = None

class OpenAIImageGenerationResponse(BaseModel):
    created: int
    data: List[OpenAIImageObject]
