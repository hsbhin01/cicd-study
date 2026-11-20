import pytest
from fastapi.testclient import TestClient

from app import main


@pytest.fixture(autouse=True)
def clear_items():
    main._items.clear()


client = TestClient(main.app)


def test_health():
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok"}


def test_create_and_get_item():
    res = client.post("/items/1", json={"name": "pen", "price": 1.5})
    assert res.status_code == 201

    res = client.get("/items/1")
    assert res.status_code == 200
    assert res.json() == {"name": "pen", "price": 1.5}


def test_duplicate_item_returns_409():
    client.post("/items/1", json={"name": "pen", "price": 1.5})
    res = client.post("/items/1", json={"name": "pen", "price": 1.5})
    assert res.status_code == 409


def test_missing_item_returns_404():
    assert client.get("/items/999").status_code == 404
