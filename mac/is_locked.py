import Quartz
d = Quartz.CGSessionCopyCurrentDictionary()
print("locked" if (d and d.get("CGSSessionScreenIsLocked")) else "unlocked")
