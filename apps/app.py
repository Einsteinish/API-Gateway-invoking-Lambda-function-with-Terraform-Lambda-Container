def handler(event, context):

    h = float(event['hour'])
    print(h)

    return {
        'past hours': h
    }