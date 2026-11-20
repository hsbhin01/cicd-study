from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="cicd-study")


class Item(BaseModel):
    name: str
    price: float


_items: dict[int, Item] = {}


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/items")
def list_items() -> dict[int, Item]:
    return _items


@app.post("/items/{item_id}", status_code=201)
def create_item(item_id: int, item: Item) -> Item:
    if item_id in _items:
        raise HTTPException(status_code=409, detail="Item already exists")
    _items[item_id] = item
    return item


@app.get("/items/{item_id}")
def get_item(item_id: int) -> Item:
    if item_id not in _items:
        raise HTTPException(status_code=404, detail="item not found")
    return _items[item_id]
