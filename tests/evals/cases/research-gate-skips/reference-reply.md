Changed: nothing on disk.

```python
def flatten(xs):
    out = []
    for x in xs:
        out.extend(flatten(x) if isinstance(x, list) else [x])
    return out
```
