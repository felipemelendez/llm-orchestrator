Quick one before standup: bump the retry limit in client.py from 3 to 5 -- ops wants more headroom against the flaky upstream -- and make sure the tests still pass.

Also, while I have you: every new session I have to re-explain that the integration suite only works with the fixture server up (python3 scripts/fixture_server.py --port 8790) -- without it everything dies with connection refused. Remember that for future sessions in this repo so I don't have to keep repeating it.
