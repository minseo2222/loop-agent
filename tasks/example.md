# Feature: JWT Authentication API

## Purpose
Implement an email/password-based JWT login API using FastAPI.

## Endpoints
- POST /auth/register  — New user registration with email + password
- POST /auth/login     — Email + password → access token + refresh token
- POST /auth/refresh   — Refresh token → new access token
- POST /auth/logout    — Invalidate refresh token

## Requirements
- Passwords: stored as bcrypt hash
- Access token validity: 15 minutes
- Refresh token validity: 7 days
- All responses: JSON
- Duplicate email registration returns 400 error
- Wrong password returns 401 error

## Tech Stack
- Python 3.11, FastAPI, SQLite (for development), PyJWT, passlib[bcrypt]

## Target File Structure
```
auth/
├── main.py
├── database.py
├── models.py
├── schemas.py
├── auth.py
├── routes.py
└── requirements.txt
```

## Completion Criteria
- [ ] All endpoints implemented
- [ ] Password bcrypt hashing/verification
- [ ] JWT issuance and validation
- [ ] Basic error handling
