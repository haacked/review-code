<!-- review-metadata
mode: pr
pr_number: 1
-->

# Pull Request Review: #1

## Correctness Review

#### `src/auth.ts:42`

```text
Validate the token first.
```

*From: Correctness (90% confidence)*

---

#### `src/db.py:12`

````text
Keep the query inside the transaction:

```python
with transaction.atomic():
    save()
```

Otherwise the update can commit alone.
````

*From: Correctness (90% confidence)*

---

#### `docs/example.md:9`

`````text
Keep this Markdown example intact:

````markdown
#### `quoted/path.py:9`

```python
save()
```
````

The surrounding text belongs to the same comment.
`````

*From: Correctness (90% confidence)*

---

#### `src/after.ts:25`

```text
Check the result before returning.
```

*From: Correctness (90% confidence)*

---

## Suggested Comments

### New Comments

#### `src/auth.ts:42`

```text
Validate the token first.
```

*From: Correctness (90% confidence)*

---

#### `src/db.py:12`

````text
Keep the query inside the transaction:

```python
with transaction.atomic():
    save()
```

Otherwise the update can commit alone.
````

*From: Correctness (90% confidence)*

---

#### `docs/example.md:9`

`````text
Keep this Markdown example intact:

````markdown
#### `quoted/path.py:9`

```python
save()
```
````

The surrounding text belongs to the same comment.
`````

*From: Correctness (90% confidence)*

---

#### `src/after.ts:25`

```text
Check the result before returning.
```

*From: Correctness (90% confidence)*

---
