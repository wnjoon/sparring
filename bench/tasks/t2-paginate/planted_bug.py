def paginate(items, page_size, page):
    if page_size < 1 or page < 1:
        raise ValueError("page_size and page must be >= 1")
    start = page * page_size
    return items[start:start + page_size]
