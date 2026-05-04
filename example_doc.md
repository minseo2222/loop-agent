# Feature: User Authentication API

## Overview

Implement a JWT-based authentication system with register, login, token refresh, and logout endpoints.
This will serve as the auth layer for all protected routes in the application.

## Requirements

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | /auth/register | Create a new user account |
| POST | /auth/login | Authenticate and return tokens |
| POST | /auth/refresh | Rotate access token using refresh token |
| POST | /auth/logout | Invalidate refresh token |

### Business Rules

- Passwords must be hashed with bcrypt before storage
- Access token expires in 15 minutes
- Refresh token expires in 7 days
- Duplicate email registration returns 409 Conflict
- Invalid credentials return 401 Unauthorized (no distinction between wrong email / wrong password)

## Tech Stack

- Language: Python 3.11
- Framework: FastAPI
- Database: SQLite (dev), PostgreSQL-compatible via SQLAlchemy
- Auth: PyJWT, passlib[bcrypt]

## Target File Structure

```
auth/
├── main.py          # FastAPI app entry point
├── models.py        # SQLAlchemy User model
├── schemas.py       # Pydantic request/response schemas
├── auth.py          # JWT encode/decode helpers
├── routes.py        # /auth/* router
├── database.py      # DB session setup
└── requirements.txt
```

## Acceptance Criteria

- [ ] All four endpoints implemented and returning correct status codes
- [ ] Passwords stored as bcrypt hashes (never plaintext)
- [ ] Access/refresh tokens issued on login, access token refreshable
- [ ] Expired or tampered tokens rejected with 401
- [ ] Basic error cases handled: duplicate email, wrong credentials, invalid token
